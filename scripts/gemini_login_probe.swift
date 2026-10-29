// gemini_login_probe.swift
// 探针：验证 Google 账号能否在 WKWebView 内完成 gemini.google.com 登录
// （QuotaMonitor 第 4 平台 Gemini 技术选型：A=内嵌 WKWebView vs B=专用 Chrome+CDP）
//
// 用法：swift gemini_login_probe.swift
// 判定：
//   - 登录成功并落到 gemini.google.com/usage → A 方案可行
//     且登录后页面 DOM 自动落盘 /tmp/gemini_usage_dom.html（选择器素材）
//   - 出现「此浏览器或应用可能不安全」/ 登录被拒 / 卡死 → 落 B 方案（专用 Chrome + CDP）
import Cocoa
import WebKit

final class AppDelegate: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate {
    var window: NSWindow!
    var webView: WKWebView!

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(
            contentRect: NSRect(x: 300, y: 200, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Gemini 登录探针 · QuotaMonitor 选型验证"

        let config = WKWebViewConfiguration()
        // 全新非持久化会话：清掉上次 Chrome UA 尝试可能留下的「不安全浏览器」标记 cookie
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        // 本机真 Safari UA（26.6.2，WebKit 冻结号 605.1.15）：
        // WKWebView 本身就是 WebKit + Apple 网络/TLS 栈，配真 Safari UA 引擎特征完全自洽，
        // 不像 Chrome UA 会因缺 window.chrome / client-hints 穿帮
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15"
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView?.addSubview(webView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        print("[probe] loading https://gemini.google.com/usage")
        webView.load(URLRequest(url: URL(string: "https://gemini.google.com/usage")!))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // target=_blank / window.open 落回同一 webview，避免新开窗口后流程断掉
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url?.absoluteString {
            print("[probe] nav -> \(url.prefix(120))")
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url?.absoluteString else { return }
        print("[probe] didFinish: \(url.prefix(120))")
        // 诊断：若停在 accounts.google.com，检查是否又是「不安全浏览器」拦截页
        if url.contains("accounts.google.com") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.checkBlockMessage()
            }
        }
        // 登录完成落回 gemini.google.com 域 → 等 SPA 渲染后抓 DOM
        if url.contains("gemini.google.com"), !url.contains("accounts.google.com") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { [weak self] in
                self?.dumpDOM()
            }
        }
    }

    func checkBlockMessage() {
        webView.evaluateJavaScript("document.body.innerText.slice(0, 400)") { result, _ in
            if let text = result as? String {
                print("[probe] accounts.google.com 页面文本：\(text.replacingOccurrences(of: "\n", with: " | ").prefix(300))")
            }
        }
    }

    func dumpDOM() {
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            if let error = error {
                print("[probe] outerHTML 抓取失败: \(error.localizedDescription)")
                return
            }
            guard let html = result as? String else {
                print("[probe] outerHTML 类型异常")
                return
            }
            let path = "/tmp/gemini_usage_dom.html"
            try? html.write(toFile: path, atomically: true, encoding: .utf8)
            let hasQuota = html.contains("当前用量") || html.contains("每周限额")
            print("[probe] DOM 落盘 \(path)（\(html.count) 字符）｜含用量字段: \(hasQuota)")
            if hasQuota {
                print("[probe] ★ 登录成功且用量页可抓 —— WKWebView 方案（A）可行")
            }
        }
    }
}

setvbuf(stdout, nil, _IONBF, 0)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
