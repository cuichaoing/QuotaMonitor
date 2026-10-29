//
//  GeminiSessionManager.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-10-29.
//  Gemini 网页会话管理：登录窗口（可见）+ 用量抓取（隐藏 WebView）+ 会话状态机。
//
//  与 API Key 型平台的本质差异（选型记录见 scripts/gemini_login_probe.swift）：
//   - 鉴权：Google 账号网页登录，cookie 持久化在 App 专属 WKWebsiteDataStore
//   - 抓取：隐藏 WKWebView 加载 gemini.google.com/usage，等 DOM 渲染出
//     [data-testid="current-usage"] 后提取（数据不在初始 HTML，必须等 JS 渲染完）
//   - UA：必须伪装完整桌面 Safari 串（裸 WKWebView UA 会被 Google 判「不安全浏览器」；
//     Chrome UA 会因缺 window.chrome / client-hints 穿帮 —— 探针实测 2026-10-29）
//   - 限频：内部 5 分钟抓取下限，不跟随三平台的智能节流高频刷 Google
//

import AppKit
import WebKit
import os

/// NetworkingService 注入用协议（测试可换 mock）
public protocol GeminiSessionProviding: Sendable {
    func fetchQuota() async throws -> ProviderQuota
}

@MainActor
public final class GeminiSessionManager: NSObject, ObservableObject {
    public static let shared = GeminiSessionManager()

    // MARK: - 常量

    static let usageURL = URL(string: "https://gemini.google.com/usage")!
    /// 完整桌面 Safari UA（与系统 Safari 同主版本，引擎/TLS 特征自洽）
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15"
    /// 抓取频率下限（秒）。Google 页面重，别跟着 30s 智能节流打
    static let minFetchInterval: TimeInterval = 300
    /// 等待 usage 页渲染出目标元素的超时（Google SPA 冷启动可能较慢）
    static let renderTimeout: TimeInterval = 45

    // MARK: - 状态

    public enum SessionState: String {
        case notLoggedIn   // 从未登录
        case loggedIn      // 登录有效
        case expired       // 曾登录，现已过期
    }

    @Published public private(set) var sessionState: SessionState {
        didSet { defaults.set(sessionState.rawValue, forKey: Keys.sessionState) }
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Gemini")

    /// App 专属持久化 cookie 仓（与 Safari / 其他 App 隔离）。
    /// 【懒加载】init 只碰 UserDefaults，绝不碰 WebKit —— 否则任何测试线程
    /// 经默认参数链触发 shared 构造时，WebKit 主线程断言会异步崩掉整个测试进程
    private lazy var dataStore: WKWebsiteDataStore = .default()
    /// 隐藏抓取 WebView（懒创建，常驻复用，避免每轮重建的冷启动开销）
    private var fetchWebView: WKWebView?
    private var offscreenWindow: NSWindow?
    /// 登录窗口强引用（开着期间保命）
    private var loginWindow: NSWindow?
    /// 自动关窗去重标志：登录流程会连续触发多次 didFinish（/app → ogs widget → …），
    /// 每次都排一个 Task 关闭窗口会导致「同一窗口被关两次」→ NSWindow 过度释放崩溃
    private var loginAutoCloseScheduled = false

    /// 抓取节流
    private var lastFetchAt: Date?
    private var cachedQuota: ProviderQuota?
    /// 抓取并发去重（同轮多个调用共享一次页面加载）
    private var inflight: Task<ProviderQuota, Error>?

    private enum Keys {
        static let sessionState = "qm.gemini.sessionState"
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Keys.sessionState)
        self.sessionState = SessionState(rawValue: raw ?? "") ?? .notLoggedIn
        super.init()
    }

    // MARK: - 登录窗口

    /// 打开可见登录窗口：用户在里面完成 Google 登录（含两步验证），
    /// 落回 gemini.google.com 域即判定会话建立，自动关窗。
    public func openLoginWindow() {
        if loginWindow != nil {
            loginWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "登录 Google Gemini"
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

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        loginAutoCloseScheduled = false
        webView.load(URLRequest(url: Self.usageURL))
        logger.info("login window opened")
    }

    /// 退出登录：清空会话数据 + 状态复位
    public func logout() async {
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
        // 频率下限：5 分钟内直接回缓存（手动刷新也不打 Google）
        if let cached = cachedQuota, let last = lastFetchAt,
           Date().timeIntervalSince(last) < Self.minFetchInterval {
            return cached
        }
        // 并发去重：同轮只有一个页面加载
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
            throw QuotaError.sessionMissing(.gemini)
        }

        let webView = ensureFetchWebView()
        webView.load(URLRequest(url: Self.usageURL))

        // 轮询：目标元素出现 / 被踢到 accounts.google.com / 落到登录墙 / 超时
        let deadline = Date().addingTimeInterval(Self.renderTimeout)
        while Date() < deadline {
            try Task.checkCancellation()

            if let url = webView.url, isLoginWall(url) {
                sessionState = .expired
                logger.error("session expired: redirected to accounts.google.com")
                throw QuotaError.sessionExpired(.gemini)
            }

            // 未登录时 usage 页会被软跳到 /app 登录墙（不跳账号域），提前收手
            if let url = webView.url, isAppLanding(url), !(await hasGoogleAuthCookies()) {
                if sessionState == .notLoggedIn {
                    throw QuotaError.sessionMissing(.gemini)
                }
                sessionState = .expired
                throw QuotaError.sessionExpired(.gemini)
            }

            let ready = (try? await evaluateBool(
                webView, script: "!!document.querySelector('[data-testid=\"current-usage\"]')")
            ) ?? false
            if ready {
                return try await extractAndBuild(webView: webView)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        // 超时收尾：区分「会话问题」与「真渲染失败」
        // 未登录时 gemini.google.com/usage 会被 JS 软跳到 /app（登录墙，HTTP 200），
        // 此时既没有 accounts.google.com 跳转、也没有认证 cookie → 判会话问题而非解析失败
        if await hasGoogleAuthCookies() {
            throw QuotaError.decodingFailed(.gemini, underlying: "usage 页渲染超时（\(Self.renderTimeout)s）")
        }
        if sessionState == .notLoggedIn {
            throw QuotaError.sessionMissing(.gemini)
        }
        sessionState = .expired
        throw QuotaError.sessionExpired(.gemini)
    }

    /// 渲染完成后从 DOM 提取并组装统一配额模型
    private func extractAndBuild(webView: WKWebView) async throws -> ProviderQuota {
        // 只取两个 <li> 块的 outerHTML，缩小解析面 + 不落整页敏感内容
        let script = """
        (function(){
          function grab(id){
            var el = document.querySelector('[data-testid="'+id+'"]');
            return el ? el.outerHTML : null;
          }
          return JSON.stringify({
            current: grab('current-usage'),
            weekly: grab('weekly-usage'),
            url: location.href
          });
        })()
        """
        guard let json = try await evaluateString(webView, script: script),
              let data = json.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuotaError.decodingFailed(.gemini, underlying: "DOM 提取脚本失败")
        }
        let currentHTML = obj["current"] as? String
        let weeklyHTML = obj["weekly"] as? String
        let finalURL = obj["url"] as? String ?? ""

        let current = GeminiUsageParser.parse(html: currentHTML ?? "")
        let weekly = GeminiUsageParser.parse(html: weeklyHTML ?? "")

        guard let currentPct = current.currentUsedPercent else {
            // 页面渲染了但拿不到数字：可能 Google 改版 / 账号无订阅
            throw QuotaError.decodingFailed(
                .gemini,
                underlying: "未能从 current-usage 块提取百分比（可能页面改版或账号无订阅）")
        }

        let now = Date()
        let primary = QuotaWindow(
            total: 100,
            used: currentPct,
            resetAt: current.currentResetText.flatMap { GeminiUsageParser.parseResetTime($0, now: now) } ?? now,
            displayName: "当前")
        let weeklyWindow = weekly.weeklyUsedPercent.map { pct in
            QuotaWindow(
                total: 100,
                used: pct,
                resetAt: weekly.weeklyResetText.flatMap { GeminiUsageParser.parseResetTime($0, now: now) } ?? now,
                displayName: "7d")
        }

        let quota = ProviderQuota(
            provider: .gemini,
            capturedAt: now,
            primaryWindow: primary,
            weeklyWindow: weeklyWindow,
            raw: [
                "currentUsedPercent": currentPct,
                "currentResetText": current.currentResetText ?? NSNull(),
                "weeklyUsedPercent": weekly.weeklyUsedPercent ?? NSNull(),
                "weeklyResetText": weekly.weeklyResetText ?? NSNull(),
                "finalURL": finalURL,
            ])

        sessionState = .loggedIn   // 抓取成功即自证会话有效
        cachedQuota = quota
        lastFetchAt = now
        // 抓完立刻卸载页面：Gemini 页面渲染后 WebContent 进程常驻 ~300MB，
        // 换 about:blank 释放 DOM/资源，等下一轮（5 分钟后）再重新加载
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        logger.info("fetched: current=\(currentPct, privacy: .public)% weekly=\(weekly.weeklyUsedPercent ?? -1, privacy: .public)%")
        return quota
    }

    // MARK: - 私有工具

    /// 隐藏 WebView：挂在 1x1 离屏窗口上（不进任何 view hierarchy 也能加载，
    /// 挂窗口是部分系统版本上 WKWebView 稳定渲染的保险做法）
    private func ensureFetchWebView() -> WKWebView {
        if let existing = fetchWebView { return existing }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720), configuration: config)
        webView.customUserAgent = Self.userAgent

        let window = NSWindow(
            contentRect: NSRect(x: -2000, y: -2000, width: 1280, height: 720),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        offscreenWindow = window

        fetchWebView = webView
        return webView
    }

    /// 登录墙判定：usage 请求被弹回 Google 账号域 = 会话失效
    private func isLoginWall(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host.hasSuffix("accounts.google.com")
    }

    /// 被动登录墙判定：未登录时 /usage 被 JS 软跳到 /app（HTTP 200，不跳账号域）
    private func isAppLanding(_ url: URL) -> Bool {
        url.path.hasPrefix("/app")
    }

    /// 认证 cookie 判据（SID/SSID/HSID/SAPISID 等 HttpOnly，JS 读不到，只能从 cookie store 读）。
    /// 这是「是否已登录」的唯一可靠信号 —— 登录墙页面本身也在 gemini.google.com 域上，
    /// 用域名单判定会误报登录成功。
    private func hasGoogleAuthCookies() async -> Bool {
        let cookies = await withCheckedContinuation { (cont: CheckedContinuation<[HTTPCookie], Never>) in
            dataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
        }
        let authNames: Set<String> = ["SID", "SSID", "HSID", "APISID", "SAPISID", "ACCOUNT_CHOOSER"]
        return cookies.contains { cookie in
            authNames.contains(cookie.name) && cookie.domain.contains("google.com")
        }
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

    private func evaluateBool(_ webView: WKWebView, script: String) async throws -> Bool {
        (try await evaluateJS(webView, script: script)) as? Bool ?? false
    }
}

// MARK: - WKNavigationDelegate（登录窗口）

extension GeminiSessionManager: WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {

    /// 登录流程落回 gemini.google.com 域后，校验认证 cookie 判定会话建立
    /// （只给登录窗口的 webview 设了 navigationDelegate，隐藏抓取 webview 不会进来）
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let url = webView.url else { return }
        guard let host = url.host, host.hasSuffix("gemini.google.com") else { return }
        // 登录墙页面也在 gemini.google.com 域上，必须用认证 cookie 复核，不能只看域名
        guard !(url.path.contains("signin")) else { return }
        // 多次 didFinish 只排一次自动关窗（否则同一窗口会被关两次 → NSWindow 过度释放崩溃）
        guard !loginAutoCloseScheduled else { return }
        loginAutoCloseScheduled = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.hasGoogleAuthCookies() else {
                // 还没拿到认证 cookie（登录墙页面本身也在该域）→ 放开标志，等下次导航再判
                self.loginAutoCloseScheduled = false
                self.logger.info("landed on gemini.google.com but no auth cookie — still signed out")
                return
            }
            self.sessionState = .loggedIn
            self.logger.info("auth cookie present — session established")

            // 稍等片刻让用户看到登录成功，再自动关窗
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let window = self.loginWindow, window.isVisible else { return }
            // 先停加载：关窗时 WebKit 仍在导航会踩 AppKit 窗口释放时序
            webView.stopLoading()
            window.close()
        }
    }

    /// target=_blank / window.open 落回同一 webview（Google 登录流程会用到）
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

    /// 窗口关闭后释放强引用。
    /// 【关键】不能在这里直接置 nil：窗口关闭动画尚未结束，NSWindow 被提前释放
    /// 会踩 AppKit 窗口释放时序（实测 v1.1.0 首启崩溃：
    /// -[_NSWindowTransformAnimation dealloc] → objc_release 过度释放）。
    /// 延迟到下一个 runloop 之后再释放，动画已收尾。
    public func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === loginWindow else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if (notification.object as? NSWindow) === self.loginWindow {
                self.loginWindow = nil
            }
            self.loginAutoCloseScheduled = false
        }
    }
}

// MARK: - NetworkingService 注入

extension GeminiSessionManager: GeminiSessionProviding {}
