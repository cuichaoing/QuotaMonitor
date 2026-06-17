//
//  QuotaMonitorApp.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  @main 入口
//

import SwiftUI

@main
struct QuotaMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // macOS 状态栏 app：仅 Settings scene（无主窗口）
        // 实际 UI 由 AppDelegate -> MenuBarController 在 applicationDidFinishLaunching 启动
        Settings {
            // v0.2 暂未实现设置页，留空避免编译错误
            EmptyView()
        }
    }
}
