import UIKit
import WebKit

/// DeepSeek 官方历史一键迁移页，对齐 Android 端 MigrationWebViewActivity。
/// 内嵌 WKWebView 打开 chat.deepseek.com，登录后自动点击「设置 → 数据管理 → 导出 → 下载」，
/// 拦截 blob / HTTP 下载落盘为 pending_migration.zip，并把路径写入待导入标记。
final class MigrationWebViewController: UIViewController, WKNavigationDelegate, WKScriptMessageHandler, WKDownloadDelegate {
    static let prefsName = "dsapp_migration"
    static let keyPendingPath = "pending_path"
    static let keyPendingName = "pending_name"
    private static let targetUrl = "https://chat.deepseek.com/"

    var onResult: ((_ filePath: String?, _ fileName: String?) -> Void)?

    private var webView: WKWebView?
    private var guideLabel: UILabel!
    private var loginPollTimer: Timer?
    private var completed = false
    private var autoExportTriggered = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let banner = UIView()
        banner.backgroundColor = UIColor(red: 0x1D / 255, green: 0x4E / 255, blue: 0xD8 / 255, alpha: 1)
        banner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(banner)

        guideLabel = UILabel()
        guideLabel.text = "请先登录 DeepSeek 账号，登录成功后将自动辅助导出"
        guideLabel.textColor = .white
        guideLabel.font = .systemFont(ofSize: 12.5)
        guideLabel.lineBreakMode = .byTruncatingTail
        guideLabel.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(guideLabel)

        let autoButton = UIButton(type: .system)
        autoButton.setTitle("自动导出", for: .normal)
        autoButton.setTitleColor(.white, for: .normal)
        autoButton.titleLabel?.font = .systemFont(ofSize: 12.5)
        autoButton.translatesAutoresizingMaskIntoConstraints = false
        autoButton.addTarget(self, action: #selector(autoExportTapped), for: .touchUpInside)
        banner.addSubview(autoButton)

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("关闭", for: .normal)
        closeButton.setTitleColor(.white, for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 12.5)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        banner.addSubview(closeButton)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "iOSMigrationBridge")
        // blob: 下载点击兜底拦截（decidePolicyFor 也会拦截，此处更早接管拿到文件名）
        let clickHook = WKUserScript(
            source: MigrationWebViewController.blobClickHookJs,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        config.userContentController.addUserScript(clickHook)

        let wv = WKWebView(frame: .zero, configuration: config)
        if #available(iOS 16.4, *) { wv.isInspectable = true }
        if let base = wv.value(forKey: "userAgent") as? String ?? wv.customUserAgent {
            wv.customUserAgent = base.replacingOccurrences(of: "; wv)", with: ")")
                .replacingOccurrences(of: "; wv", with: "")
        }
        wv.navigationDelegate = self
        wv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(wv)
        webView = wv

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.heightAnchor.constraint(equalToConstant: 44),
            guideLabel.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            guideLabel.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            guideLabel.trailingAnchor.constraint(lessThanOrEqualTo: autoButton.leadingAnchor, constant: -8),
            autoButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            autoButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            wv.topAnchor.constraint(equalTo: banner.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            wv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        if let url = URL(string: Self.targetUrl) {
            wv.load(URLRequest(url: url))
        }
        loginPollTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            self?.checkLoginState()
        }
    }

    @objc private func closeTapped() {
        finish(filePath: nil, fileName: nil)
    }

    @objc private func autoExportTapped() {
        guideLabel.text = "正在尝试自动点击导出，请稍候..."
        runAutoExportScript(manualTrigger: true)
    }

    // MARK: - 登录态检测（对齐 Android checkLoginState）

    private func checkLoginState() {
        guard webView != nil, !autoExportTriggered, !completed else { return }
        let js = """
        (function(){
            if (location.hostname !== 'chat.deepseek.com') return;
            var p = location.pathname || '';
            if (p.indexOf('sign_in') >= 0 || p.indexOf('login') >= 0) return;
            var hasInput = !!document.querySelector('textarea');
            var hasPassInput = !!document.querySelector('input[type="password"]');
            if (hasInput && !hasPassInput) {
                window.webkit.messageHandlers.iOSMigrationBridge.postMessage({event:'onLoggedIn'});
            }
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - 自动导出脚本（对齐 Android runAutoExportScript）

    private func runAutoExportScript(manualTrigger: Bool) {
        guard webView != nil, !completed else { return }
        let resetJs = manualTrigger
            ? "if (window.__dsappAutoExportTimer) { clearInterval(window.__dsappAutoExportTimer); window.__dsappAutoExportTimer = null; } window.__dsappAutoExportRunning = false;"
            : ""
        let js = """
        (function(){
        \(resetJs)
        if (window.__dsappAutoExportRunning) return;
        window.__dsappAutoExportRunning = true;
        var bridge = function(payload) {
            try { window.webkit.messageHandlers.iOSMigrationBridge.postMessage(payload); } catch (e) {}
        };
        var triggerClick = function(el) {
            if (!el) return false;
            var target = (el.closest && el.closest('button, [role="button"], [role="menuitem"], [role="tab"], [tabindex="0"], a')) || el;
            if (!target || typeof target.click !== 'function') return false;
            try { target.scrollIntoView({ block: 'nearest', inline: 'center' }); } catch (e) {}
            target.click();
            return true;
        };
        var findVisibleByText = function(patterns, excludeDanger) {
            var nodes = Array.from(document.querySelectorAll('button, [role="button"], [role="menuitem"], [role="tab"], [tabindex="0"], a, li, div, span'));
            var best = null;
            var bestLen = 999;
            var bestArea = 999999999;
            for (var i = 0; i < nodes.length; i++) {
                var el = nodes[i];
                var rect = el.getBoundingClientRect();
                if (rect.width <= 0 || rect.height <= 0) continue;
                var text = (el.innerText || '').trim();
                var label = (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title') || '') || '').trim();
                if (label && (!text || text.length > 32 || !patterns.some(function(p){ return p.test(text); }))) { text = label; }
                if (!text || text.length > 32) continue;
                if (excludeDanger && /^(删除|Delete)$/i.test(text)) continue;
                for (var j = 0; j < patterns.length; j++) {
                    if (patterns[j].test(text)) {
                        var area = rect.width * rect.height;
                        if (text.length < bestLen || (text.length === bestLen && area < bestArea)) {
                            best = el;
                            bestLen = text.length;
                            bestArea = area;
                        }
                        break;
                    }
                }
            }
            return best;
        };
        var clickHamburger = function() {
            var els = Array.from(document.querySelectorAll('[tabindex="0"], button, [role="button"], div'));
            var best = null;
            var bestArea = 999999;
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var r = el.getBoundingClientRect();
                if (r.width >= 20 && r.width <= 72 && r.height >= 20 && r.height <= 72 && r.left >= 0 && r.left < 80 && r.top >= 0 && r.top < 110 && el.querySelector('svg')) {
                    var area = r.width * r.height;
                    if (area < bestArea) { best = el; bestArea = area; }
                }
            }
            return triggerClick(best);
        };
        var clickProfileBar = function() {
            var els = Array.from(document.querySelectorAll('[tabindex="0"], button, [role="button"]'));
            for (var i = 0; i < els.length; i++) {
                var el = els[i];
                if (el.tagName === 'A') continue;
                var r = el.getBoundingClientRect();
                if (r.width >= 120 && r.width <= 340 && r.height >= 32 && r.height <= 80 && r.left >= 0 && r.left < 80 && r.bottom > window.innerHeight - 90) {
                    return triggerClick(el);
                }
            }
            return false;
        };
        var ticks = 0;
        var exportClicked = false;
        var lastSection = '';
        var lastAction = '';
        var lastActionTick = -10;
        var timer = setInterval(function() {
            try {
                ticks++;
                var maxTicks = exportClicked ? 260 : 30;
                if (ticks > maxTicks) {
                    clearInterval(timer);
                    window.__dsappAutoExportTimer = null;
                    window.__dsappAutoExportRunning = false;
                    bridge({event:'onAutoExportTimeout'});
                    return;
                }
                var confirmBtn = findVisibleByText([/^(确认导出|确认|确定|Confirm)$/i], true);
                if (confirmBtn && triggerClick(confirmBtn)) {
                    bridge({event:'onStep', msg:'Clicked Confirm'});
                    return;
                }
                if (lastSection === 'data' || findVisibleByText([/导出所有历史对话|Export all/i], true)) {
                    var dlBtn = findVisibleByText([/^(下载|Download)$/i], true);
                    if (dlBtn && triggerClick(dlBtn)) {
                        bridge({event:'onStep', msg:'Clicked Download'});
                        clearInterval(timer);
                        window.__dsappAutoExportTimer = null;
                        window.__dsappAutoExportRunning = false;
                        return;
                    }
                    if (!exportClicked) {
                        var expBtn = findVisibleByText([/^(导出数据|导出|Export Data|Export)$/i], true);
                        if (expBtn && triggerClick(expBtn)) {
                            exportClicked = true;
                            bridge({event:'onStep', msg:'Clicked Export'});
                            bridge({event:'onWaitingExport'});
                            return;
                        }
                    }
                    return;
                }
                if (findVisibleByText([/^(通用设置|账号管理|General|Account)$/i], true) || findVisibleByText([/^(数据管理|Data Controls|Data management|Data)$/i], true)) {
                    var dataTab = findVisibleByText([/^(数据管理|Data Controls|Data management|Data)$/i], true);
                    if (dataTab && triggerClick(dataTab)) {
                        lastSection = 'data';
                        bridge({event:'onStep', msg:'Clicked Data tab'});
                        return;
                    }
                }
                var settingsItem = findVisibleByText([/^(系统设置|Settings)$/i], true);
                if (settingsItem && triggerClick(settingsItem)) {
                    bridge({event:'onStep', msg:'Clicked System Settings'});
                    return;
                }
                if (findVisibleByText([/^(开启新对话|New chat)$/i], true)) {
                    if (lastAction !== 'profile' || ticks - lastActionTick >= 3) {
                        if (clickProfileBar()) {
                            lastAction = 'profile';
                            lastActionTick = ticks;
                            bridge({event:'onStep', msg:'Clicked Profile bar'});
                        }
                    }
                    return;
                }
                if (lastAction !== 'hamburger' || ticks - lastActionTick >= 3) {
                    if (clickHamburger()) {
                        lastAction = 'hamburger';
                        lastActionTick = ticks;
                        bridge({event:'onStep', msg:'Clicked Hamburger'});
                    }
                }
            } catch (err) {
                bridge({event:'onStep', msg:'ERR: ' + err});
            }
        }, 700);
        window.__dsappAutoExportTimer = timer;
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - blob 下载接管

    /// document 起始注入：拦截 a[download] 的 blob 点击，直接 fetch 转 base64 回传。
    private static let blobClickHookJs = """
    (function(){
        if (window.__dsappBlobHookInstalled) return;
        window.__dsappBlobHookInstalled = true;
        var bridge = function(payload) {
            try { window.webkit.messageHandlers.iOSMigrationBridge.postMessage(payload); } catch (e) {}
        };
        document.addEventListener('click', function(e) {
            try {
                var node = e.target;
                var a = node && node.closest ? node.closest('a[download], a[href^="blob:"]') : null;
                if (!a) return;
                var href = a.href || '';
                if (!href.startsWith('blob:')) return;
                e.preventDefault();
                e.stopPropagation();
                var name = (a.getAttribute('download') || 'deepseek_data.zip');
                fetch(href).then(function(r){ return r.blob(); }).then(function(b){
                    var rd = new FileReader();
                    rd.onloadend = function(){
                        var s = rd.result || '';
                        var i = s.indexOf(',');
                        bridge({event:'onBlobDownloaded', data: i >= 0 ? s.slice(i+1) : s, name: name});
                    };
                    rd.readAsDataURL(b);
                }).catch(function(err){ bridge({event:'onBlobError', error: String(err)}); });
            } catch (err) {}
        }, true);
    })();
    """

    /// decidePolicyFor 兜底：WKWebView 对 blob: 导航也可能走到这里。
    private func fetchBlobUrl(_ urlString: String, suggestedName: String) {
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return }
        let js = """
        (function(){
            var bridge = function(payload) {
                try { window.webkit.messageHandlers.iOSMigrationBridge.postMessage(payload); } catch (e) {}
            };
            fetch(decodeURIComponent('\(encoded)'))
            .then(function(r){ return r.blob(); })
            .then(function(b){
                var rd = new FileReader();
                rd.onloadend = function(){
                    var s = rd.result || '';
                    var i = s.indexOf(',');
                    bridge({event:'onBlobDownloaded', data: i >= 0 ? s.slice(i+1) : s, name: '\(suggestedName)'});
                };
                rd.readAsDataURL(b);
            })
            .catch(function(e){ bridge({event:'onBlobError', error: String(e)}); });
        })();
        """
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if let urlString = navigationAction.request.url?.absoluteString, urlString.hasPrefix("blob:") {
            decisionHandler(.cancel)
            fetchBlobUrl(urlString, suggestedName: "deepseek_data.zip")
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        let mime = response.mimeType ?? ""
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let path = response.url?.path.lowercased() ?? ""
        let isAttachment = disposition.lowercased().contains("attachment")
            || mime == "application/zip"
            || mime == "application/octet-stream"
            || path.hasSuffix(".zip")
        if isAttachment {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !autoExportTriggered {
            checkLoginState()
        }
    }

    // MARK: - WKDownloadDelegate（HTTP/HTTPS 附件落盘）

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pending_migration.zip")
        try? FileManager.default.removeItem(at: dest)
        return dest
    }

    func downloadDidFinish(_ download: WKDownload) {
        // WKDownload 不暴露目标 URL；decideDestinationUsing 里返回固定路径。
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pending_migration.zip")
        finishWithFile(dest, fileName: "deepseek_data.zip")
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        DispatchQueue.main.async { [weak self] in
            self?.guideLabel.text = "下载接管失败: \(error.localizedDescription)"
        }
    }

    // MARK: - JS 桥回调

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "iOSMigrationBridge", !completed else { return }
        guard let body = message.body as? [String: Any], let event = body["event"] as? String else { return }
        switch event {
        case "onLoggedIn":
            if autoExportTriggered || completed { return }
            autoExportTriggered = true
            DispatchQueue.main.async { [weak self] in
                self?.guideLabel.text = "已检测到登录，正在自动打开设置并导出..."
                self?.runAutoExportScript(manualTrigger: false)
            }
        case "onStep":
            break
        case "onWaitingExport":
            DispatchQueue.main.async { [weak self] in
                self?.guideLabel.text = "已触发官方导出，正在等待生成导出包（约需 1-3 分钟，生成后将自动下载）..."
            }
        case "onAutoExportTimeout":
            DispatchQueue.main.async { [weak self] in
                self?.guideLabel.text = "未定位到按钮，请手动点「设置 → 数据管理 → 导出/下载」"
            }
        case "onBlobDownloaded":
            guard let base64 = body["data"] as? String,
                  let data = Data(base64Encoded: base64) else {
                guideLabel.text = "解析导出包失败"
                return
            }
            let fileName = (body["name"] as? String)?.lowercased().hasSuffix(".zip") == true
                ? body["name"] as! String
                : "deepseek_data.zip"
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("pending_migration.zip")
            do {
                try data.write(to: dest)
                finishWithFile(dest, fileName: fileName)
            } catch {
                guideLabel.text = "解析导出包失败"
            }
        case "onBlobError":
            guideLabel.text = "导出失败: \(body["error"] as? String ?? "")"
        default:
            break
        }
    }

    // MARK: - 收尾（对齐 Android finishWithFile：持久化待导入标记）

    private func finishWithFile(_ file: URL, fileName: String) {
        if completed { return }
        completed = true
        UserDefaults.standard.set(file.path, forKey: Self.keyPendingPath)
        UserDefaults.standard.set(fileName, forKey: Self.keyPendingName)
        finish(filePath: file.path, fileName: fileName)
    }

    private func finish(filePath: String?, fileName: String?) {
        loginPollTimer?.invalidate()
        loginPollTimer = nil
        dismiss(animated: true) { [weak self] in
            self?.onResult?(filePath, fileName)
        }
    }

    deinit {
        loginPollTimer?.invalidate()
    }
}
