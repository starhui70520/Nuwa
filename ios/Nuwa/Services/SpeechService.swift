import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var recordingSeconds: Int = 0
    @Published var audioLevel: Float = 0.0
    @Published var isSpeaking = false
    @Published var speakingMessageId: UUID?
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recordTimer: Timer?
    private var ttsTask: Task<Void, Never>?
    private var pcmEngine: AVAudioEngine?
    private var pcmPlayerNode: AVAudioPlayerNode?

    // For cloud ASR fallback (records 16kHz mono PCM WAV)
    private var recordedSamples: [Int16] = []
    private var usingCloudAsr = false
    private var onCloudTranscript: (@MainActor (String) -> Void)?
    private var cloudSecret: String = ""
    private var cloudBaseUrl: String = ""

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - Read Aloud (Native + Cloud DeepSeek TTS /v1/tools/tts)

    func toggleSpeak(messageId: UUID, text: String, settings: SettingsStore) {
        if isSpeaking && speakingMessageId == messageId {
            stopSpeaking()
            return
        }
        stopSpeaking()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }

        let preferCloud = settings.speechEngine == .cloud
            || (settings.speechEngine == .auto && !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && settings.isDeepSeekOfficial)

        if preferCloud && !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            speakCloud(messageId: messageId, text: cleaned, settings: settings)
        } else {
            speakNative(messageId: messageId, text: cleaned, voiceOption: settings.ttsVoice)
        }
    }

    private func speakNative(messageId: UUID, text: String, voiceOption: TtsVoiceOption) {
        let spokenText = Self.stripMarkdownForTts(text)
        guard !spokenText.isEmpty else {
            stopSpeaking()
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {}

        let utterance = AVSpeechUtterance(string: spokenText)
        let hasChinese = spokenText.range(of: "\\p{Han}", options: .regularExpression) != nil
        let lang = hasChinese ? "zh-CN" : "en-US"
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(hasChinese ? "zh" : "en") }
        if voiceOption == .tide, let male = voices.first(where: { $0.gender == .male }) {
            utterance.voice = male
        } else if voiceOption == .stella, let female = voices.first(where: { $0.gender == .female }) {
            utterance.voice = female
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingMessageId = messageId
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    static func stripMarkdownForTts(_ raw: String) -> String {
        var s = raw
        let rules: [(String, String)] = [
            ("```[\\s\\S]*?```", " "),
            ("\\[citation:\\d+\\]", ""),
            ("!\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),
            ("\\[([^\\]]+)\\]\\([^)]*\\)", "$1"),
            ("`([^`]*)`", "$1"),
            ("(?m)^\\s{0,3}#{1,6}\\s+", ""),
            ("(?m)^\\s{0,3}>\\s?", ""),
            ("(?m)^\\s*[-*+]\\s+", ""),
            ("(?m)^\\s*\\d+\\.\\s+", ""),
            ("[*_~]+", ""),
            ("\\s+", " "),
        ]
        for (pattern, replacement) in rules {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
            }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func speakCloud(messageId: UUID, text: String, settings: SettingsStore) {
        speakingMessageId = messageId
        isSpeaking = true
        let key = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = AIClient.normalizeOrigin(settings.effectiveBaseUrl)
        let voiceId = settings.ttsVoice.rawValue

        ttsTask = Task {
            guard let url = URL(string: "\(origin)/v1/tools/tts") else {
                speakNative(messageId: messageId, text: text, voiceOption: settings.ttsVoice)
                return
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 30
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "text": text,
                "voice_id": voiceId,
                "format": "pcm",
                "filter_markdown": true,
            ])

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode), !data.isEmpty else {
                    speakNative(messageId: messageId, text: text, voiceOption: settings.ttsVoice)
                    return
                }
                playPCM24kHz(data: data)
            } catch is CancellationError {
                stopSpeaking()
            } catch {
                speakNative(messageId: messageId, text: text, voiceOption: settings.ttsVoice)
            }
        }
    }

    private func playPCM24kHz(data: Data) {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)

            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            engine.attach(player)

            guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24000, channels: 1, interleaved: true) else {
                stopSpeaking()
                return
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)
            try engine.start()

            let frameCount = UInt32(data.count / 2)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                stopSpeaking()
                return
            }
            buffer.frameLength = frameCount
            data.withUnsafeBytes { raw in
                if let src = raw.bindMemory(to: Int16.self).baseAddress,
                   let dst = buffer.int16ChannelData?[0] {
                    dst.update(from: src, count: Int(frameCount))
                }
            }

            pcmEngine = engine
            pcmPlayerNode = player
            player.scheduleBuffer(buffer) { [weak self] in
                Task { @MainActor in
                    self?.stopSpeaking()
                }
            }
            player.play()
        } catch {
            stopSpeaking()
        }
    }

    func stopSpeaking() {
        ttsTask?.cancel()
        ttsTask = nil
        pcmPlayerNode?.stop()
        pcmEngine?.stop()
        pcmPlayerNode = nil
        pcmEngine = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        speakingMessageId = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakingMessageId = nil
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.speakingMessageId = nil
        }
    }

    // MARK: - Voice Recording (Native SFSpeechRecognizer + Cloud ASR + Live Metering)

    func toggleRecording(settings: SettingsStore, onTranscript: @escaping @MainActor (String) -> Void) {
        if isRecording {
            finishRecording()
            return
        }
        Task {
            await startRecording(settings: settings, onTranscript: onTranscript)
        }
    }

    private func startRecording(settings: SettingsStore, onTranscript: @escaping @MainActor (String) -> Void) async {
        errorMessage = nil
        let hasDeepSeekKey = !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && settings.isDeepSeekOfficial
        let canCloud = settings.speechEngine == .cloud && !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (settings.speechEngine == .auto && hasDeepSeekKey)

        if !canCloud {
            let authStatus = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard authStatus == .authorized else {
                errorMessage = "请在系统设置中开启语音识别权限。"
                return
            }
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            errorMessage = "请在系统设置中开启麦克风权限。"
            return
        }

        stopSpeaking()
        cancelRecording()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            usingCloudAsr = canCloud
            recordedSamples.removeAll()
            onCloudTranscript = onTranscript
            cloudSecret = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            cloudBaseUrl = settings.effectiveBaseUrl

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)

            if canCloud {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                    guard let self else { return }
                    let level = Self.computeRMS(buffer)
                    let samples = Self.extractInt16Samples(buffer)
                    Task { @MainActor in
                        self.audioLevel = level
                        self.recordedSamples.append(contentsOf: samples)
                    }
                }
            } else {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.shouldReportPartialResults = true
                recognitionRequest = request

                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
                    request.append(buffer)
                    let level = Self.computeRMS(buffer)
                    Task { @MainActor in
                        self?.audioLevel = level
                    }
                }

                let recognizerLocale = settings.locale == .enUS ? Locale(identifier: "en-US") : Locale(identifier: "zh-CN")
                speechRecognizer = SFSpeechRecognizer(locale: recognizerLocale)
                recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                    if let result {
                        let transcript = result.bestTranscription.formattedString
                        Task { @MainActor in
                            onTranscript(transcript)
                        }
                    }
                    if error != nil || (result?.isFinal ?? false) {
                        Task { @MainActor in
                            self?.cleanupAudioEngine()
                        }
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            recordingSeconds = 0
            recordTimer?.invalidate()
            recordTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.recordingSeconds += 1
                    if self.recordingSeconds >= 120 {
                        self.finishRecording()
                    }
                }
            }
        } catch {
            errorMessage = "无法启动语音输入：\(error.localizedDescription)"
            cancelRecording()
        }
    }

    func finishRecording() {
        let wasCloud = usingCloudAsr
        let samples = recordedSamples
        let sampleRate = Int(audioEngine.inputNode.outputFormat(forBus: 0).sampleRate)
        let callback = onCloudTranscript
        cleanupAudioEngine()

        if wasCloud && !samples.isEmpty {
            let wav = Self.encodeWav(samples: samples, sampleRate: max(sampleRate, 16000))
            isTranscribing = true
            Task {
                defer { isTranscribing = false }
                do {
                    let text = try await uploadCloudASR(wavData: wav)
                    if !text.isEmpty { callback?(text) }
                } catch {
                    errorMessage = "语音识别失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func cancelRecording() {
        recognitionTask?.cancel()
        cleanupAudioEngine()
        recordedSamples.removeAll()
        isTranscribing = false
    }

    private func cleanupAudioEngine() {
        recordTimer?.invalidate()
        recordTimer = nil
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        audioLevel = 0
    }

    private func uploadCloudASR(wavData: Data) async throws -> String {
        let origin = AIClient.normalizeOrigin(cloudBaseUrl)
        guard let url = URL(string: "\(origin)/v1/tools/asr") else {
            throw AIClientError.invalidURL
        }
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(cloudSecret)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw AIClientError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0, "云端识别不可用")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = obj["text"] as? String {
            return text
        }
        throw AIClientError.decodingError
    }

    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameCount {
            let v = data[i]
            sum += v * v
        }
        let rms = sqrt(sum / Float(frameCount))
        return min(1.0, max(0.0, rms * 6.0))
    }

    private static func extractInt16Samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard let data = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        var out = [Int16]()
        out.reserveCapacity(count)
        for i in 0..<count {
            let clamped = max(-1.0, min(1.0, data[i]))
            out.append(Int16(clamped * Float(Int16.max)))
        }
        return out
    }

    private static func encodeWav(samples: [Int16], sampleRate: Int) -> Data {
        var data = Data()
        let pcmByteCount = UInt32(samples.count * 2)
        let chunkSize = 36 + pcmByteCount
        let byteRate = UInt32(sampleRate * 2)
        data.append("RIFF".data(using: .ascii)!)
        appendLE(&data, chunkSize)
        data.append("WAVEfmt ".data(using: .ascii)!)
        appendLE(&data, UInt32(16))
        appendLE(&data, UInt16(1))
        appendLE(&data, UInt16(1))
        appendLE(&data, UInt32(sampleRate))
        appendLE(&data, byteRate)
        appendLE(&data, UInt16(2))
        appendLE(&data, UInt16(16))
        data.append("data".data(using: .ascii)!)
        appendLE(&data, pcmByteCount)
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                data.append(UnsafeBufferPointer(start: base, count: ptr.count))
            }
        }
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ val: T) {
        var le = val.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
