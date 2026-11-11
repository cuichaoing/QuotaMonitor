//
//  BaiduSessionManager.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-11-11.
//  百度千帆 Token Plan 网页会话管理：登录窗口（可见）+ 用量抓取（隐藏 WebView）+ 会话状态机。
//
//  与 GeminiSessionManager 同构（选型原因一致）：
//   - 千帆 Token Plan 没有公开的「用量/余额查询 API」，只能登录控制台网页抓取
//   - 鉴权：百度账号网页登录，cookie 持久化在 App 专属 WKWebsiteDataStore
//   - 抓取：隐藏 WKWebView 加载 console.bce.baidu.com/qianfan/resource/token-plan，
//     等 DOM 渲染出「剩余 / 总量」后提取（数据不在初始 HTML，必须等 JS 渲染完）
//   - 指标：包月总量制（非 5h 滚动窗口）——「剩余 X / 总量 Y Token」+「重置时间」
//   - 限频：内部 5 分钟抓取下限
//

import AppKit
import WebKit
import os

/// NetworkingService 注入用协议（测试可换 mock）
public protocol BaiduSessionProviding: Sendable {
    func fetchQuota() async throws -> ProviderQuota
}

@MainActor
public final class BaiduSessionManager: NSObject, ObservableObject {
    public static let shared = BaiduSessionManager()

    // MARK: - 常量

    static let usageURL = URL(string: "https://console.bce.baidu.com/qianfan/resource/token-plan")!
    /// 完整桌面 Safari UA（百度和 Google 一样，裸 WKWebView UA 会被判「不安全浏览器」）
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15"
    /// 抓取频率下限（秒），跟 Gemini 一致
    static let minFetchInterval: TimeInterval = 300
    /// 等待页面渲染出「余量」区块的超时（百度控制台是重 SPA，比 Gemini 慢）
    static let renderTimeout: TimeInterval = 60

    // MARK: - 状态

    public enum SessionState: String {
        case notLoggedIn
        case loggedIn
        case expired
    }

    @Published public private(set) var sessionState: SessionState {
        didSet { defaults.set(sessionState.rawValue, forKey: Keys.sessionState) }
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Baidu")

    /// 懒加载：init 只碰 UserDefaults，绝不碰 WebKit（否则测试线程经默认参数链触发 shared 构造会崩）
    private lazy var dataStore: WKWebsiteDataStore = .default()
    private var fetchWebView: WKWebView?
    private var offscreenWindow: NSWindow?
    private var loginWindow: NSWindow?
    /// 登录窗里的 WebView（复用窗口时用它重新加载目标页）
    private var loginWebView: WKWebView?
    private var loginAutoCloseScheduled = false

    private var lastFetchAt: Date?
    private var cachedQuota: ProviderQuota?
    private var inflight: Task<ProviderQuota, Error>?

    private enum Keys {
        static let sessionState = "qm.baidu.sessionState"
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Keys.sessionState)
        self.sessionState = SessionState(rawValue: raw ?? "") ?? .notLoggedIn
        super.init()
    }

    // MARK: - 登录窗口

    public func openLoginWindow() {
        if let win = loginWindow {
            // 【BUG-2026-11-11-01/02】窗口**复用**而不是重建：
            // 旧实现关闭后把 loginWindow 置 nil，等于 release 一个 AppKit 可能已释放的
            // NSWindow → objc_release 野指针 → EXC_BAD_ACCESS 崩主线程（两次实测）。
            // 现在永不释放窗口，只重新加载目标页（cookie 仍在同一 WKWebsiteDataStore）。
            loginWebView?.load(URLRequest(url: Self.usageURL))
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            loginAutoCloseScheduled = false
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "登录百度千帆"
        window.center()

        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        webView.customUserAgent = Self.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView?.addSubview(webView)
        window.delegate = self
        self.loginWindow = window
        self.loginWebView = webView

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loginAutoCloseScheduled = false
        webView.load(URLRequest(url: Self.usageURL))
        logger.info("login window opened")
    }

    public func logout() async {
        // 磁盘 cookie 一并清掉，否则退出登录后重启又被灌回来
        try? FileManager.default.removeItem(at: Self.cookieStoreURL)
        dataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast
        ) { [weak self] in
            guard let self else { return }
            self.sessionState = .notLoggedIn
            self.cachedQuota = nil
            self.lastFetchAt = nil
        }
        logger.info("logged out, session data cleared")
    }

    // MARK: - 抓取（NetworkingService 调用入口）

    public func fetchQuota() async throws -> ProviderQuota {
        // app 重启后先把磁盘 cookie 灌回来（免重登）
        await restoreCookies()
        await logCookieState()
        if let cached = cachedQuota, let last = lastFetchAt,
           Date().timeIntervalSince(last) < Self.minFetchInterval {
            return cached
        }
        if let running = inflight {
            return try await running.value
        }
        let task = Task<ProviderQuota, Error> { [weak self] in
            guard let self else { throw QuotaError.cancelled }
            return try await self.performFetch()
        }
        inflight = task
        defer { inflight = nil }
        return try await task.value
    }

    private func performFetch() async throws -> ProviderQuota {
        guard sessionState != .notLoggedIn else {
            throw QuotaError.sessionMissing(.baidu)
        }

        let webView = ensureFetchWebView()
        webView.load(URLRequest(url: Self.usageURL))

        var lastBlock = ""
        var lastLen = -1
        var stagnantRounds = 0
        var reloads = 0
        var suspectLoginURL: URL?
        var suspectLoginSince: Date?
        let deadline = Date().addingTimeInterval(Self.renderTimeout)
        while Date() < deadline {
            try Task.checkCancellation()

            // 疑似登录墙：跳到百度通行证域，或 URL 里带 login。
            // 【必须持续 3 秒以上才算真登录墙】—— 百度控制台加载时会经 SSO 中转页
            // （URL 也可能带 login），一次就判过期会把正常会话误杀成「登录过期」。
            if let url = webView.url, looksLikeLoginWall(url) {
                if suspectLoginURL == url, let since = suspectLoginSince,
                   Date().timeIntervalSince(since) > 3 {
                    sessionState = .expired
                    logger.error("session expired: stuck on a login URL")
                    throw QuotaError.sessionExpired(.baidu)
                }
                if suspectLoginURL != url {
                    suspectLoginURL = url
                    suspectLoginSince = Date()
                }
            } else {
                suspectLoginURL = nil
                suspectLoginSince = nil
            }

            // 轮询：切到「余量」区块且里面有数字 → 认为页面已渲染出用量
            if let extracted = try? await evaluateExtractScript(webView) {
                lastBlock = extracted.block
                if extracted.hasNumbers {
                    return try await build(webView: webView, extracted: extracted)
                }
            }

            // [BUG-2026-11-11-06] **渲染停滞检测**：SPA 可能卡在骨架（innerText 一直不增长）。
            // 实测同一进程里先后创建多个 WebView 加载重 SPA 时，后一个会一直停在骨架；
            // reload 一次往往就能渲染出来。连续 4 轮（≈2 秒）长度不变就 reload，最多 2 次。
            let curLen = lastBlock.count
            if curLen == lastLen, curLen > 0 {
                stagnantRounds += 1
                if stagnantRounds >= 4, reloads < 2 {
                    reloads += 1
                    stagnantRounds = 0
                    lastLen = -1
                    logger.info("render stagnant (\(curLen) chars) — reloading page")
                    webView.reload()
                }
            } else {
                stagnantRounds = 0
            }
            lastLen = curLen

            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 超时收尾：**不猜**「登录过期」，统一报「没取到用量」并带上页面原文。
        // （诊断 JSON 会导出 underlying → 能直接看出是没登录、页面改版还是被风控；
        //   真正的登录墙由上面的「持续 3 秒停在登录页」判定负责抛 sessionExpired）
        let hint = lastBlock.isEmpty
            ? "（用量区块为空：页面可能未渲染 / 未登录 / 被风控）"
            : "（页面原文：\(lastBlock.prefix(300))）"
        await persistCookies()
        throw QuotaError.decodingFailed(
            .baidu,
            underlying: "token-plan 页未取到用量（\(Int(Self.renderTimeout))s）\(hint)")
    }

    // MARK: - JS 提取

    /// JS 端提取脚本：把控制台页 `body.innerText` 里的三个关键数字抠出来。
    /// 返回的 JSON 串：{ remaining, total, remainPercent, resetAt, url }
    /// JS 端只做一件事：**切出「余量」区块的原文**，不做数字解析。
    ///
    /// [BUG-2026-11-11-02] 初版把「剩余 X / 总量 Y」的中文正则写在 JS 里，
    /// 页面真实文案一变（插「Token」、全角斜杠、数字带单位）就失配，
    /// 表现为「渲染超时」且**丢掉原文无从诊断**。改为：
    ///   JS → 区块原文；Swift → 解析（可单测、失败时原文随报错带出）。
    private static let extractScript = """
    (function(){
      try {
        var text = (document.body && document.body.innerText) || '';
        // 「套餐余量」优先，退到「余量」「剩余」「套餐」
        var keys = ['套餐余量', '余量', '剩余', '套餐'];
        var idx = -1;
        for (var i = 0; i < keys.length; i++) {
          var p = text.indexOf(keys[i]);
          if (p >= 0) { idx = p; break; }
        }
        var block = idx >= 0 ? text.substring(idx, idx + 600) : '';
        return JSON.stringify({ block: block, url: location.href });
      } catch (e) {
        return JSON.stringify({ block:'', url: location.href });
      }
    })()
    """

    private struct Extracted {
        let block: String
        let url: String
        /// 区块里出现了数字，才认为页面真的渲染出了用量
        var hasNumbers: Bool {
            block.range(of: #"[0-9]"#, options: .regularExpression) != nil
        }
    }

        private func evaluateExtractScript(_ webView: WKWebView) async throws -> Extracted {
        guard let json = try await evaluateString(webView, script: Self.extractScript),
              let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decodingFailed(.baidu, underlying: "DOM 提取脚本失败")
        }
        return Extracted(
            block: obj["block"] as? String ?? "",
            url: obj["url"] as? String ?? "")
    }

    /// 页面是否已经渲染出用量内容（登录成功的第二判据：光有 BDUSS 不算数）
    private func pageShowsUsage(_ webView: WKWebView) async -> Bool {
        guard let extracted = try? await evaluateExtractScript(webView) else { return false }
        return extracted.hasNumbers
    }

    /// 宽松的「看起来已登录」判据：已离开登录页 + 有百度 cookie
    /// （不按 cookie 名判 —— console.bce.baidu.com 的 cookie 名与通行证域不同）
    private func looksLoggedIn(_ webView: WKWebView) async -> Bool {
        guard let url = webView.url else { return false }
        let s = url.absoluteString
        if s.contains("login") || s.contains("passport") { return false }
        return await baiduCookieCount() > 0
    }

    private func build(webView: WKWebView, extracted: Extracted) async throws -> ProviderQuota {
        let now = Date()
        guard let quota = BaiduUsageParser.parse(block: extracted.block, capturedAt: now) else {
            throw QuotaError.decodingFailed(
                .baidu,
                underlying: "未能从 token-plan 页提取用量（页面原文：\(extracted.block.prefix(300))）")
        }

        sessionState = .loggedIn
        cachedQuota = quota
        lastFetchAt = now
        // 抓完卸载页面释放资源（同 Gemini）
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        await persistCookies()
        logger.info("fetched: used=\(quota.primaryUsedPercent ?? -1, privacy: .public)%")
        return quota
    }

    // MARK: - Cookie 持久化

    /// cookie 落盘路径。
    ///
    /// [BUG-2026-11-11-03] macOS 上**非沙盒** app 的 WKWebView 不会把 cookie 持久化到磁盘
    /// （实测 `~/Library/WebKit/app.quotamonitor/WebsiteData/Default/Cookies` 始终 0 字节，
    ///  localStorage 也是空的）→ 每次 app 重启都要重新登录百度。
    /// 这里自己把 cookie 导出到磁盘、启动时再灌回去，不依赖 WebKit 的磁盘策略。
    private static var cookieStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("baidu_cookies.json")
    }

    /// 把百度相关 cookie 落盘（登录成功 / 抓取成功后调用）
    private func persistCookies() async {
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            dataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        let baidu = cookies.filter { $0.domain.contains("baidu.com") }
        guard !baidu.isEmpty else { return }
        let payload: [[String: Any]] = baidu.map { c in
            [
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": c.isSecure,
                "expires": c.expiresDate?.timeIntervalSince1970 ?? NSNull(),
            ]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: Self.cookieStoreURL, options: .atomic)
        logger.info("persisted \(baidu.count, privacy: .public) baidu cookies")
    }

    /// 从磁盘把 cookie 灌回 WebKit（app 启动 / 每次抓取前调用，幂等）
    private func restoreCookies() async {
        guard let data = try? Data(contentsOf: Self.cookieStoreURL),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        var restored = 0
        for d in arr {
            guard let name = d["name"] as? String,
                  let value = d["value"] as? String,
                  let domain = d["domain"] as? String else { continue }
            var props: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: domain,
                .path: d["path"] as? String ?? "/",
                .secure: d["secure"] as? Bool ?? false,
            ]
            if let exp = d["expires"] as? Double {
                props[.expires] = Date(timeIntervalSince1970: exp)
            }
            if let cookie = HTTPCookie(properties: props) {
                await dataStore.httpCookieStore.setCookie(cookie)
                restored += 1
            }
        }
        if restored > 0 {
            logger.info("restored \(restored, privacy: .public) baidu cookies from disk")
        }
    }

    // MARK: - 私有工具

    /// 隐藏抓取 WebView：挂在**屏幕内**的 1x1 窗口上。
    ///
    /// [BUG-2026-11-11-05] 原实现挂在 (-2000,-2000) 的离屏窗口上（照抄 Gemini），
    /// 但 **macOS 不合成屏幕外窗口 → WebKit 不渲染 SPA**：
    /// 同一页面 `document.body.innerText` 在离屏时只有 165 字符（骨架），
    /// 放屏幕内则是 1541 字符、能完整拿到「余量 / 剩余 / 总量 / 重置时间」。
    /// → 千帆控制台这种重 SPA 在离屏窗口里永远抓不到用量。
    /// 现在：窗口放在屏幕右下角、1x1 像素、alpha 0.02、orderBack 不激活、
    /// ignoresMouseEvents 不吃鼠标事件 —— 视觉与交互上无感，但确实在屏幕内。
    /// 注入脚本：屏蔽页面里的密码输入框。
    ///
    /// [BUG-2026-11-12-01 根治] WebKit 的密码自动填充会因页面里存在 `<input type=password>`
    /// 而去访问 macOS 钥匙串 → 弹 SecurityAgent 授权框。该框是 **app-modal**，
    /// 一旦弹出，app 就进入 modal session → **MainActor 被挂起 → refresh 永不执行**
    /// （实测：杀掉弹窗后 app 立刻恢复抓取）。
    /// 控制台页面即使已登录，DOM 里仍可能残留隐藏的登录框 → 统统改成 text，让 WebKit 认不出。
    private static let suppressPasswordInputs = """
    (function(){
      function scrub(){
        try {
          document.querySelectorAll('input[type="password"]').forEach(function(el){
            el.setAttribute('type', 'text');
            el.removeAttribute('autocomplete');
            el.setAttribute('data-quotamonitor-noautofill', '1');
          });
        } catch(e) {}
      }
      scrub();
      document.addEventListener('DOMContentLoaded', scrub);
      new MutationObserver(function(){ scrub(); }).observe(document.documentElement || document, {childList:true, subtree:true});
    })();
    """

    private func ensureFetchWebView() -> WKWebView {
        if let existing = fetchWebView { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        config.userContentController.addUserScript(
            WKUserScript(source: Self.suppressPasswordInputs, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 360), configuration: config)
        webView.customUserAgent = Self.userAgent

        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        // 窗口保持**完整尺寸**（contentView 会被裁剪 —— 窗口只有 2x2 时 webView 被裁到 2x2 就不渲染了），
        // 只把**位置**挪到屏幕右缘之外，屏幕内仅露出 2px 窄条（用户看不见，但窗口确实在屏幕内 → macOS 会合成 → WebKit 渲染 SPA）
        let window = NSWindow(
            contentRect: NSRect(x: screen.maxX - 2, y: screen.minY, width: 480, height: 360),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.alphaValue = 0.02
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        offscreenWindow = window

        fetchWebView = webView
        return webView
    }

    /// 疑似登录墙判定：跳到百度通行证域，或 URL 里带 login
    private func looksLikeLoginWall(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        if host.hasSuffix("passport.baidu.com") { return true }
        return url.absoluteString.contains("login")
    }

    /// 百度 cookie 数量（仅用于日志/诊断）。
    /// 【注意】**不要**按 cookie 名判断登录态：百度的登录 cookie 因域而异
    /// （BDUSS 是通行证域 passport.baidu.com 的，console.bce.baidu.com 用的是另一套），
    /// 实测按 BDUSS 判定会永远判不出登录 → 误报「登录过期」。
    /// 可靠的登录判据是「页面渲染出用量内容」（见 pageShowsUsage）。
    private func baiduCookieCount() async -> Int {
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            dataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        return cookies.filter { $0.domain.contains("baidu.com") }.count
    }

    /// 恢复 cookie 后打一条日志：cookie 数是判断「登录态还在不在」的最直接信号
    private func logCookieState() async {
        let n = await baiduCookieCount()
        logger.info("baidu cookies in memory: \(n, privacy: .public)")
    }

    @discardableResult
    private func evaluateJS(_ webView: WKWebView, script: String) async throws -> AnyObject? {
        try await withCheckedThrowingContinuation { cont in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume(returning: result as AnyObject?)
                }
            }
        }
    }

    private func evaluateString(_ webView: WKWebView, script: String) async throws -> String? {
        try await evaluateJS(webView, script: script) as? String
    }
}

// MARK: - WKNavigationDelegate（登录窗口）

extension BaiduSessionManager: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {

    /// 登录流程落回 console.bce.baidu.com 域后，轮询等待「我的订阅」内容渲染出来
    ///
    /// [BUG-2026-11-11-04] 之前只在 `didFinish` 里判一次「页面有没有用量」——
    /// 但千帆控制台是 SPA，**数据是 JS 渲染的**：`didFinish` 触发时只有骨架，
    /// 渲染完成**不会**再触发一次 didFinish → 判定永远不通过 → 从不设 loggedIn、
    /// 从不落盘 cookie → 抓取时被判「登录过期」。改为在 didFinish 之后**轮询等待**。
    ///
    /// 登录判据用「页面渲染出用量」而不是 cookie 名：百度的登录 cookie 因域而异
    /// （BDUSS 是通行证域的，console.bce.baidu.com 用的是另一套），按名字判不可靠。
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        guard let host = url.host, host.hasSuffix("bce.baidu.com") else { return }
        guard !loginAutoCloseScheduled else { return }
        loginAutoCloseScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(Self.renderTimeout)
            while Date() < deadline {
                // 登录判据：① 页面渲染出用量（最可靠）；② 或者已离开登录页且有百度 cookie
                let showsUsage = await self.pageShowsUsage(webView)
                let loggedIn = showsUsage ? true : await self.looksLoggedIn(webView)
                if loggedIn {
                    self.sessionState = .loggedIn
                    await self.persistCookies()
                    self.logger.info("usage rendered — session established")

                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let window = self.loginWindow, window.isVisible else { return }
                    webView.stopLoading()
                    // 卸载登录页：WebKit 渲染进程会常驻 ~300MB，且与抓取 WebView 抢资源
                    // （实测同进程多个 WebView 加载重 SPA 会互相干扰，导致另一个停在骨架）
                    // —— 换 about:blank 释放 DOM/资源，cookie 不受影响。
                    webView.load(URLRequest(url: URL(string: "about:blank")!))
                    window.close()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // 超时：仍把 cookie 落盘（便于诊断真实 cookie 名单），但不判登录成功
            await self.persistCookies()
            self.loginAutoCloseScheduled = false
            self.logger.info("login window: usage not rendered within timeout")
        }
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    public func windowWillClose(_ notification: Notification) {
        // 【关键 · BUG-2026-11-11-01/02】这里**绝不释放窗口**：
        // 实测两次 EXC_BAD_ACCESS @ objc_release —— 崩在延迟闭包执行 `self.loginWindow = nil`
        // 时，release 的是 AppKit 可能已释放的 NSWindow（野指针）。
        // 百度登录流程（点历史登录记录、多次导航）会把这个窗口推到该状态。
        // 改为：窗口保持存活，下次 openLoginWindow 复用（重新 load 目标页）。
        loginAutoCloseScheduled = false
    }
}

// MARK: - NetworkingService 注入

extension BaiduSessionManager: BaiduSessionProviding {}