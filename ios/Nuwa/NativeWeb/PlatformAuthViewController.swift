import CryptoKit
import UIKit
import WebKit

/// DeepSeek 开放平台 PKCE 授权登录页，对齐 Android 端 PlatformAuthActivity。
/// auth_init / auth_exchange / auth_cancel 直连 platform.deepseek.com，
/// redirect_uri 使用 http://127.0.0.1:<端口>/oauth/callback 并由 WKNavigationDelegate 拦截。
final class PlatformAuthViewController: UIViewController, WKNavigationDelegate {
    private static let platformOrigin = "https://platform.deepseek.com"
    private static let clientVersion = "0.2.2"
    private static let deviceIdKey = "dsapp_platform_auth.device_id"

    /// 授权结束后回调：token 非空为成功；error 非空为失败；均为 nil 为用户取消。
    var onResult: ((_ token: String?, _ accountLabel: String?, _ error: String?) -> Void)?

    private var webView: WKWebView?
    private var statusLabel: UILabel!
    private var verifier: String?
    private var state: String?
    private var redirectUri: String?
    private var authorizeId: String?
    private var exchanging = false
    private var completed = false

    private static func wireLocale() -> String {
        let lang: String
        if #available(iOS 16.0, *) {
            lang = Locale.current.language.languageCode?.identifier ?? "zh"
        } else {
            lang = Locale.current.languageCode ?? "zh"
        }
        return lang.lowercased().hasPrefix("zh") ? "zh_CN" : "en_US"
    }

    private static func clientHeaders() -> [String: String] {
        [
            "x-client-bundle-id": "",
            "x-client-platform": "web",
            "x-client-version": clientVersion,
            "x-client-locale": wireLocale(),
            "x-client-timezone-offset": String(TimeZone.current.secondsFromGMT()),
            "Content-Type": "application/json",
        ]
    }

    private static func randomBase64Url(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func sha256Base64Url(_ input: String) -> String {
        let digest = SHA256.hash(data: Data(input.utf8))
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func deviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: deviceIdKey)
        return created
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let banner = UIView()
        banner.backgroundColor = UIColor(red: 0x18 / 255, green: 0x18 / 255, blue: 0x1B / 255, alpha: 1)
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)

        let bannerContent = UIView()
        bannerContent.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerContent)

        statusLabel = UILabel()
        statusLabel.text = "正在连接 DeepSeek 开放平台..."
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 13)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bannerContent.addSubview(statusLabel)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        bannerContent.addSubview(closeButton)

        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: .zero, configuration: config)
        // 去掉 WebView "; wv" 标记，避免第三方 OAuth 登录被拦截
        if let base = wv.value(forKey: "userAgent") as? String ?? wv.customUserAgent {
            wv.customUserAgent = base.replacingOccurrences(of: "; wv)", with: ")")
                .replacingOccurrences(of: "; wv", with: "")
        }
        wv.navigationDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)
        webView = wv

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bannerContent.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            bannerContent.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            bannerContent.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            bannerContent.bottomAnchor.constraint(equalTo: banner.bottomAnchor, constant: -2),
            bannerContent.heightAnchor.constraint(equalToConstant: 44),
            statusLabel.leadingAnchor.constraint(equalTo: bannerContent.leadingAnchor, constant: 16),
            statusLabel.centerYAnchor.constraint(equalTo: bannerContent.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -10),
            closeButton.trailingAnchor.constraint(equalTo: bannerContent.trailingAnchor, constant: -16),
            closeButton.centerYAnchor.constraint(equalTo: bannerContent.centerYAnchor),
            wv.topAnchor.constraint(equalTo: banner.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        startPkceInit()
    }

    @objc private func closeTapped() {
        finish(token: nil, label: nil)
    }

    private func startPkceInit() {
        let verifier = Self.randomBase64Url(32)
        let state = Self.randomBase64Url(32)
        let challenge = Self.sha256Base64Url(verifier)
        let port = 30000 + Int(arc4random_uniform(25000))
        let redirectUri = "http://127.0.0.1:\(port)/oauth/callback"
        self.verifier = verifier
        self.state = state
        self.redirectUri = redirectUri

        let body: [String: Any] = [
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
            "redirect_uri": redirectUri,
            "locale": Self.wireLocale(),
            "login_source": "web",
        ]

        Task {
            do {
                let bizData = try await postPlatform("auth_init", body: body)
                guard let authUrl = bizData["authorize_url"] as? String,
                      authUrl.hasPrefix("\(Self.platformOrigin)/dsh/authorize") else {
                    throw NSError(domain: "PlatformAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unexpected authorize_url"])
                }
                authorizeId = bizData["authorize_id"] as? String
                await MainActor.run {
                    statusLabel.text = "请登录并授权 Nuwa 使用你的 DeepSeek API 账号"
                    if let url = URL(string: authUrl) {
                        webView?.load(URLRequest(url: url))
                    }
                }
            } catch {
                await MainActor.run {
                    statusLabel.text = "连接开放平台失败，请检查网络后重试"
                }
                finish(token: nil, label: nil, error: error.localizedDescription)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let urlString = navigationAction.request.url?.absoluteString,
              let redirect = redirectUri,
              urlString.hasPrefix(redirect) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if exchanging || completed {
            return
        }
        let queryItems = URLComponents(string: urlString)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: queryItems.map { ($0.name, $0.value ?? "") })
        guard query["state"] == state, let code = query["code"], !code.isEmpty else {
            showToast("授权回调校验失败，请重试")
            return
        }
        exchanging = true
        statusLabel.text = "授权成功，正在获取账号令牌..."
        Task { await exchange(code) }
    }

    private func exchange(_ code: String) async {
        do {
            let body: [String: Any] = [
                "code": code,
                "code_verifier": verifier ?? "",
                "redirect_uri": redirectUri ?? "",
                "device_id": Self.deviceId(),
                "device_model": "\(UIDevice.current.model)-\(UIDevice.current.name)",
                "os_version": "iOS \(UIDevice.current.systemVersion)",
            ]
            let bizData = try await postPlatform("auth_exchange", body: body)
            guard let token = bizData["token"] as? String, !token.isEmpty else {
                throw NSError(domain: "PlatformAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "empty token"])
            }
            let label = extractLabel(bizData["user"] as? [String: Any])
            completed = true
            finish(token: token, label: label)
        } catch {
            exchanging = false
            await MainActor.run {
                statusLabel.text = "换取账号令牌失败，正在刷新授权页面..."
            }
            await MainActor.run { startPkceInit() }
        }
    }

    private func extractLabel(_ user: [String: Any]?) -> String {
        if let idProfile = user?["id_profile"] as? [String: Any],
           let name = idProfile["name"] as? String,
           !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name.trimmingCharacters(in: .whitespaces)
        }
        for key in ["mobile", "mobile_number", "email"] {
            if let val = user?[key] as? String, !val.trimmingCharacters(in: .whitespaces).isEmpty {
                return val.trimmingCharacters(in: .whitespaces)
            }
        }
        return "DeepSeek API 账号"
    }

    private func postPlatform(_ method: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "\(Self.platformOrigin)/auth-api/v0/dsh/\(method)")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        Self.clientHeaders().forEach { request.setValue($1, forHTTPHeaderField: $0) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "PlatformAuth", code: -1, userInfo: [NSLocalizedDescriptionKey: "无效响应"])
        }
        if http.statusCode == 429 {
            AppLogStore.shared.record(.warn, source: "platformAuth.\(method)", message: "HTTP 429 rate limited")
            throw NSError(domain: "PlatformAuth", code: 429, userInfo: [NSLocalizedDescriptionKey: "请求过于频繁，请稍后再试（HTTP 429）"])
        }
        guard (200..<300).contains(http.statusCode) else {
            AppLogStore.shared.record(.error, source: "platformAuth.\(method)", message: "HTTP \(http.statusCode)")
            throw NSError(domain: "PlatformAuth", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "开放平台授权失败（HTTP \(http.statusCode)）"])
        }
        guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (envelope["code"] as? Int) == 0 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["msg"] as? String
            AppLogStore.shared.record(.error, source: "platformAuth.\(method)", message: msg ?? "envelope error")
            throw NSError(domain: "PlatformAuth", code: -2, userInfo: [NSLocalizedDescriptionKey: msg ?? "开放平台授权失败"])
        }
        guard let bizData = envelope["data"] as? [String: Any],
              (bizData["biz_code"] as? Int) == 0 else {
            let bizMsg = (envelope["data"] as? [String: Any])?["biz_msg"] as? String
            AppLogStore.shared.record(.error, source: "platformAuth.\(method)", message: bizMsg ?? "biz error")
            throw NSError(domain: "PlatformAuth", code: -3, userInfo: [NSLocalizedDescriptionKey: bizMsg ?? "开放平台授权校验失败"])
        }
        return bizData["biz_data"] as? [String: Any] ?? [:]
    }

    private func showToast(_ text: String) {
        statusLabel.text = text
    }

    private func finish(token: String?, label: String?, error: String? = nil) {
        // 中途退出时对齐 Android：通知平台取消本次授权
        if !completed, let cancelId = authorizeId, let verifier {
            let body: [String: Any] = ["authorize_id": cancelId, "code_verifier": verifier]
            Task.detached { try? await self.postPlatform("auth_cancel", body: body) }
        }
        dismiss(animated: true) { [weak self] in
            self?.onResult?(token, label, error)
        }
    }
}
