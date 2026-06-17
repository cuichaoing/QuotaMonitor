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
        // 1. 启动菜单栏
        menuBarController = MenuBarController(appState: appState)

        // 2. 启动数据流（AppState.bootstrap 会启动 scheduler + 立即拉一次）
        appState.bootstrap()

        // 3. 确保不显示在 Dock
        NSApp.setActivationPolicy(.accessory)
    }

    public func applicationWillTerminate(_ notification: Notification) {
        appState.shutdown()
    }

    /// 阻止弹出主窗口
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
