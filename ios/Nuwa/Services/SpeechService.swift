import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var isRecording = false
    @Published var isSpeaking = false
    @Published var speakingMessageId: UUID?
    @Published var errorMessage: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggleSpeak(messageId: UUID, text: String) {
        if isSpeaking && speakingMessageId == messageId {
            stopSpeaking()
            return
        }
        stopSpeaking()
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Continue with default session
        }
        let utterance = AVSpeechUtterance(string: cleaned)
        let hasChinese = cleaned.range(of: "\\p{Han}", options: .regularExpression) != nil
        utterance.voice = AVSpeechSynthesisVoice(language: hasChinese ? "zh-CN" : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speakingMessageId = messageId
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
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

    func toggleRecording(onTranscript: @escaping @MainActor (String) -> Void) {
        if isRecording {
            stopRecording()
            return
        }
        Task {
            await startRecording(onTranscript: onTranscript)
        }
    }

    private func startRecording(onTranscript: @escaping @MainActor (String) -> Void) async {
        errorMessage = nil
        let authStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        guard authStatus == .authorized else {
            errorMessage = "请在系统设置中开启语音识别权限。"
            return
        }

        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            errorMessage = "请在系统设置中开启麦克风权限。"
            return
        }

        stopSpeaking()
        stopRecording()

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                request.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true

            recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    Task { @MainActor in
                        onTranscript(transcript)
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    Task { @MainActor in
                        self?.stopRecording()
                    }
                }
            }
        } catch {
            errorMessage = "无法启动语音输入：\(error.localizedDescription)"
            stopRecording()
        }
    }

    func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }
}
