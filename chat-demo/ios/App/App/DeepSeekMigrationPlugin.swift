import AVFAudio
import AVFoundation
import Capacitor
import Foundation
import Speech

/// iOS 端 DeepSeekMigration 插件：对齐 Android 同名插件的账号授权登录接口。
/// startPlatformAuth 打开内嵌 WKWebView 授权页并直接把 token 作为结果返回；
/// consumePendingPlatformAuth / logoutPlatformAuth 为接口对齐保留。
@objc(DeepSeekMigration)
public class DeepSeekMigrationPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "DeepSeekMigrationPlugin"
    public let jsName = "DeepSeekMigration"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "startPlatformAuth", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "consumePendingPlatformAuth", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "logoutPlatformAuth", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openExportBrowser", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "consumePendingExport", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "clearPendingExport", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "ensureMicrophonePermission", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "startSpeechRecognition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeechRecognition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "cancelSpeechRecognition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "speakText", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopSpeaking", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "saveFileToDocuments", returnType: CAPPluginReturnPromise),
    ]

    private var pendingAuthCall: CAPPluginCall?

    // MARK: 原生语音识别（SFSpeechRecognizer + AVAudioEngine，对齐 Android SpeechRecognizer）
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var speechCommitted = ""
    private var speechPartial = ""
    private var speechActive = false
    private var pendingStopCall: CAPPluginCall?
    private var lastRmsEmitMs: UInt64 = 0

    // MARK: 原生朗读（AVSpeechSynthesizer，对齐 Android TextToSpeech）
    private var speechSynthesizer: AVSpeechSynthesizer?
    private var activeUtteranceId: String?
    private var pendingChunkCount = 0

    @objc func startPlatformAuth(_ call: CAPPluginCall) {
        if pendingAuthCall != nil {
            call.reject("AUTH_IN_PROGRESS")
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let presenter = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?.rootViewController
            guard let presenter else {
                call.reject("NO_PRESENTER")
                return
            }
            let authVC = PlatformAuthViewController()
            authVC.modalPresentationStyle = .fullScreen
            authVC.onResult = { token, label, error in
                self.pendingAuthCall = nil
                if let token, !token.isEmpty {
                    call.resolve(["token": token, "accountLabel": label ?? "DeepSeek API 账号"])
                } else if let error {
                    call.reject(error)
                } else {
                    call.resolve()
                }
            }
            self.pendingAuthCall = call
            presenter.present(authVC, animated: true)
        }
    }

    /// iOS 通过 promise 直接返回 token，无 pending 态可消费。
    @objc func consumePendingPlatformAuth(_ call: CAPPluginCall) {
        call.resolve(["hasPending": false])
    }

    /// 打开内嵌迁移浏览器；导出包落盘后 resolve {filePath, fileName}，取消则 resolve 空对象。
    @objc func openExportBrowser(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let presenter = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }?.rootViewController
            guard let presenter else {
                call.reject("NO_PRESENTER")
                return
            }
            let vc = MigrationWebViewController()
            vc.modalPresentationStyle = .fullScreen
            vc.onResult = { filePath, fileName in
                if let filePath {
                    call.resolve(["filePath": filePath, "fileName": fileName ?? "deepseek_data.zip"])
                } else {
                    call.resolve()
                }
            }
            presenter.present(vc, animated: true)
        }
    }

    /// 崩溃/重启兜底：读取持久化的待导入标记（对齐 Android SharedPreferences）。
    @objc func consumePendingExport(_ call: CAPPluginCall) {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: MigrationWebViewController.keyPendingPath)
        let name = defaults.string(forKey: MigrationWebViewController.keyPendingName) ?? "deepseek_data.zip"
        guard let path, FileManager.default.fileExists(atPath: path) else {
            defaults.removeObject(forKey: MigrationWebViewController.keyPendingPath)
            defaults.removeObject(forKey: MigrationWebViewController.keyPendingName)
            call.resolve(["hasPending": false])
            return
        }
        call.resolve(["hasPending": true, "filePath": path, "fileName": name])
    }

    @objc func clearPendingExport(_ call: CAPPluginCall) {
        let defaults = UserDefaults.standard
        if let path = defaults.string(forKey: MigrationWebViewController.keyPendingPath) {
            try? FileManager.default.removeItem(atPath: path)
        }
        defaults.removeObject(forKey: MigrationWebViewController.keyPendingPath)
        defaults.removeObject(forKey: MigrationWebViewController.keyPendingName)
        call.resolve()
    }

    @objc func logoutPlatformAuth(_ call: CAPPluginCall) {
        guard let token = call.getString("token"), !token.isEmpty else {
            call.resolve()
            return
        }
        var request = URLRequest(url: URL(string: "https://platform.deepseek.com/auth-api/v0/users/logout")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        let offsetSeconds = TimeZone.current.secondsFromGMT()
        let lang = Locale.current.languageCode ?? "zh"
        request.setValue("", forHTTPHeaderField: "x-client-bundle-id")
        request.setValue("web", forHTTPHeaderField: "x-client-platform")
        request.setValue("0.2.2", forHTTPHeaderField: "x-client-version")
        request.setValue(lang.lowercased().hasPrefix("zh") ? "zh_CN" : "en_US", forHTTPHeaderField: "x-client-locale")
        request.setValue(String(offsetSeconds), forHTTPHeaderField: "x-client-timezone-offset")
        request.setValue(token, forHTTPHeaderField: "x-dsh-auth-token")
        URLSession.shared.dataTask(with: request) { _, _, _ in call.resolve() }.resume()
    }

    /// 在 WKWebView 里派发 CustomEvent（对齐 Android emitWebEvent）。
    private func emitWebEvent(_ js: String) {
        DispatchQueue.main.async {
            self.bridge?.webView?.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    private func emitRmsLevel(_ level: Float) {
        emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-rms',{detail:\(level)}))")
    }

    private func emitSpeechError(_ detail: String) {
        emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:speech-error',{detail:'\(detail)'}))")
    }

    private func emitTtsState(_ id: String, _ state: String) {
        emitWebEvent("window.dispatchEvent(new CustomEvent('dsapp:tts-state',{detail:{id:'\(id)',state:'\(state)'}}));")
    }

    // MARK: 麦克风权限

    @objc func ensureMicrophonePermission(_ call: CAPPluginCall) {
        switch AVAudioSession.sharedInstance().recordPermission {
        case .granted:
            call.resolve(["granted": true])
        case .denied:
            call.resolve(["granted": false])
        default:
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                call.resolve(["granted": granted])
            }
        }
    }

    // MARK: 语音识别

    private func destroySpeechRecognizerInternal() {
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        if let engine = audioEngine {
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            audioEngine = nil
        }
        speechRecognizer = nil
    }

    private func combinedSpeechText() -> String {
        (speechCommitted + speechPartial).trimmingCharacters(in: .whitespaces)
    }

    private func finishPendingStop() {
        guard let stopCall = pendingStopCall else { return }
        pendingStopCall = nil
        let text = combinedSpeechText()
        speechCommitted = ""
        speechPartial = ""
        speechActive = false
        destroySpeechRecognizerInternal()
        stopCall.resolve(["text": text])
    }

    @objc func startSpeechRecognition(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            if AVAudioSession.sharedInstance().recordPermission != .granted {
                call.reject("PERMISSION_DENIED")
                return
            }
            let localeRaw = (call.getString("locale") ?? "").trimmingCharacters(in: .whitespaces)
            let speechLocale = Locale(identifier: localeRaw.isEmpty ? "zh-CN" : localeRaw)
            guard let recognizer = SFSpeechRecognizer(locale: speechLocale) else {
                call.reject("UNAVAILABLE")
                return
            }
            guard SFSpeechRecognizer.authorizationStatus() != .denied, SFSpeechRecognizer.authorizationStatus() != .restricted else {
                call.reject("PERMISSION_DENIED")
                return
            }
            if SFSpeechRecognizer.authorizationStatus() != .authorized {
                SFSpeechRecognizer.requestAuthorization { status in
                    DispatchQueue.main.async {
                        if status == .authorized {
                            self.startSpeechRecognition(call)
                        } else {
                            call.reject("PERMISSION_DENIED")
                        }
                    }
                }
                return
            }
            guard recognizer.isAvailable else {
                call.reject("UNAVAILABLE")
                return
            }

            self.destroySpeechRecognizerInternal()
            self.speechCommitted = ""
            self.speechPartial = ""
            self.speechActive = true
            self.pendingStopCall = nil
            self.speechRecognizer = recognizer

            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
                try session.setActive(true, options: .notifyOthersOnDeactivation)
            } catch {
                self.speechActive = false
                call.reject("START_FAILED: \(error.localizedDescription)")
                return
            }

            let engine = AVAudioEngine()
            self.audioEngine = engine
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.recognitionRequest = request

            let inputNode = engine.inputNode
            let hwFormat = inputNode.outputFormat(forBus: 0)
            // 模拟器等无输入硬件时 hwFormat 无效：跳过 tap，仅跑识别任务（返回空文本而不崩溃）
            if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
                guard let self = self else { return }
                request.append(buffer)
                let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
                if now - self.lastRmsEmitMs < 40 {
                    return
                }
                self.lastRmsEmitMs = now
                // 按 Android 的归一化近似：float PCM 转 RMS 再映射到 0-1
                guard let channelData = buffer.floatChannelData else { return }
                let count = Int(buffer.frameLength)
                if count == 0 { return }
                var sum: Float = 0
                for i in 0..<count {
                    let s = channelData[0][i]
                    sum += s * s
                }
                let rms = sqrt(sum / Float(count))
                let rmsdB = 20 * log10(max(rms, 1e-6))
                let level = max(0, min(1, (rmsdB + 2) / 12 + 0.3))
                self.emitRmsLevel(level)
                }
            }

            self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self = self else { return }
                if let result = result {
                    let text = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.speechCommitted += text
                        self.speechPartial = ""
                        if self.pendingStopCall != nil {
                            self.finishPendingStop()
                        }
                    } else {
                        self.speechPartial = text
                    }
                }
                if let error = error {
                    if self.pendingStopCall != nil {
                        self.finishPendingStop()
                        return
                    }
                    guard self.speechActive else { return }
                    self.speechActive = false
                    self.destroySpeechRecognizerInternal()
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101 {
                        self.emitSpeechError("PERMISSION_DENIED")
                    } else if self.combinedSpeechText().isEmpty {
                        self.emitSpeechError("FAILED")
                    }
                }
            }

            do {
                if hwFormat.sampleRate > 0 && hwFormat.channelCount > 0 {
                    try engine.start()
                }
                call.resolve()
            } catch {
                self.speechActive = false
                self.destroySpeechRecognizerInternal()
                call.reject("START_FAILED: \(error.localizedDescription)")
            }
        }
    }

    @objc func stopSpeechRecognition(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.speechActive = false
            guard self.recognitionTask != nil else {
                let text = self.combinedSpeechText()
                self.speechCommitted = ""
                self.speechPartial = ""
                call.resolve(["text": text])
                return
            }
            if let prev = self.pendingStopCall {
                prev.resolve(["text": ""])
            }
            self.pendingStopCall = call
            // 结束音频输入后等待最终结果回调
            self.recognitionRequest?.endAudio()
            self.audioEngine?.inputNode.removeTap(onBus: 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                self.finishPendingStop()
            }
        }
    }

    @objc func cancelSpeechRecognition(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.speechActive = false
            if let prev = self.pendingStopCall {
                self.pendingStopCall = nil
                prev.resolve(["text": ""])
            }
            self.speechCommitted = ""
            self.speechPartial = ""
            self.destroySpeechRecognizerInternal()
            call.resolve()
        }
    }

    // MARK: 朗读

    private func ensureSynthesizer() -> AVSpeechSynthesizer {
        if let existing = speechSynthesizer {
            return existing
        }
        let synthesizer = AVSpeechSynthesizer()
        synthesizer.delegate = self
        speechSynthesizer = synthesizer
        return synthesizer
    }

    private func splitTtsChunks(_ text: String, maxLen: Int) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLen, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }

    @objc func speakText(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let text = (call.getString("text") ?? "").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else {
                call.reject("EMPTY_TEXT")
                return
            }
            let locale = (call.getString("locale") ?? "zh-CN").lowercased()
            let language = locale.hasPrefix("en") ? "en-US" : "zh-CN"
            let synthesizer = self.ensureSynthesizer()
            let utteranceId = UUID().uuidString
            self.activeUtteranceId = utteranceId

            let chunks = self.splitTtsChunks(text, maxLen: 3800)
            self.pendingChunkCount = chunks.count
            for chunk in chunks {
                let utterance = AVSpeechUtterance(string: chunk)
                utterance.voice = AVSpeechSynthesisVoice(language: language)
                synthesizer.speak(utterance)
            }
            call.resolve(["utteranceId": utteranceId])
        }
    }

    @objc func stopSpeaking(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            self.activeUtteranceId = nil
            self.pendingChunkCount = 0
            self.speechSynthesizer?.stopSpeaking(at: .immediate)
            call.resolve()
        }
    }

    // MARK: 导出文件（iCloud Drive / 本地存储，系统文件面板，无需开发者账号）

    @objc func saveFileToDocuments(_ call: CAPPluginCall) {
        DispatchQueue.main.async {
            let name = (call.getString("name") ?? "").trimmingCharacters(in: .whitespaces)
            let base64 = call.getString("data") ?? ""
            guard !name.isEmpty, let data = Data(base64Encoded: base64) else {
                call.reject("INVALID_DATA")
                return
            }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                call.reject("WRITE_FAILED: \(error.localizedDescription)")
                return
            }
            guard let root = self.bridge?.viewController else {
                call.reject("NO_VIEW")
                return
            }
            var presenter = root
            while let presented = presenter.presentedViewController {
                presenter = presented
            }
            let picker = UIDocumentPickerViewController(forExporting: [url])
            presenter.present(picker, animated: true) {
                call.resolve(["presented": true])
            }
        }
    }
}

extension DeepSeekMigrationPlugin: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        if let id = activeUtteranceId {
            emitTtsState(id, "playing")
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard let id = activeUtteranceId else { return }
        pendingChunkCount = max(0, pendingChunkCount - 1)
        if pendingChunkCount == 0 {
            activeUtteranceId = nil
            emitTtsState(id, "done")
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard let id = activeUtteranceId else { return }
        pendingChunkCount = max(0, pendingChunkCount - 1)
        if pendingChunkCount == 0 {
            activeUtteranceId = nil
            emitTtsState(id, "done")
        }
    }
}
