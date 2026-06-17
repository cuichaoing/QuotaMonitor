//
//  LoginItemManager.swift
//  QuotaMonitor
//
//  封装 SMAppService 登录项管理
//

import AppKit
import ServiceManagement

/// 管理 QuotaMonitor 的开机自动启动（登录项）。
/// 使用 Apple 主推的 SMAppService API（macOS 13+）。
@MainActor
public final class LoginItemManager: @unchecked Sendable {
    public static let shared = LoginItemManager()

    /// 打开"系统设置 → 登录项"的 URL
    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    /// 当前登录项状态
    public var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    private init() {}

    /// 将主应用注册为登录项。
    /// 抛出异常表示注册失败（如未授权、服务未找到等）。
    public func register() throws {
        try SMAppService.mainApp.register()
    }

    /// 取消主应用的登录项注册。
    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// 打开系统设置中的"登录项"页面，引导用户手动允许。
    public func openSystemSettings() {
        guard let url = Self.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
