//
//  AppDelegate.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  AppKit 入口：启动时创建 MenuBarController，结束时优雅停机
//

import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public let appState = AppState.shared
    private var menuBarController: MenuBarController?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. 关闭 WebKit 的密码自动填充/保存（必须在任何 WebView 创建之前）
        //    [BUG-2026-11-12-01] WKWebView 里的登录表单会自动访问 macOS 钥匙串，
        //    弹出的 SecurityAgent 授权框在无头/后台场景下点不动、会挂住整个登录流程。
        //    我们只用 cookie 维持会话，不需要 WebKit 碰钥匙串。
        UserDefaults.standard.set(false, forKey: "WebKitPasswordAutosaveEnabled")
        UserDefaults.standard.set(false, forKey: "WebKitPasswordAutoFillEnabled")

        // 1. 启动菜单栏
        menuBarController = MenuBarController(appState: appState)

        // 2. 同步开机自启状态：确保 SMAppService 与 SettingsStore 一致
        syncLaunchAtLogin()

        // 3. 启动数据流
        appState.bootstrap()

        // 4. 确保不显示在 Dock
        NSApp.setActivationPolicy(.accessory)
    }

    private func syncLaunchAtLogin() {
        let settings = appState.settings
        let manager = LoginItemManager.shared
        let status = manager.status

        // 用户想开启，但系统未注册或需要授权 → 尝试注册
        if settings.launchAtLogin {
            if status == .notRegistered {
                try? manager.register()
            }
        } else {
            // 用户想关闭，但系统仍注册 → 注销
            if status == .enabled || status == .requiresApproval {
                try? manager.unregister()
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    /// 阻止弹出主窗口
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
