//
//  NotificationManager.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  系统通知封装：UNUserNotificationCenter 极薄包装
//

import Foundation
import UserNotifications
import os

@MainActor
public final class NotificationManager: NSObject, @unchecked Sendable {
    public static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Notifications")

    public override init() {
        super.init()
        center.delegate = self
    }

    // MARK: - 权限

    /// 请求通知权限。返回 true = 已授权
    @discardableResult
    public func requestPermission() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("requestAuthorization failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 当前权限状态
    public func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - 投递告警

    /// 投递单个告警事件
    public func send(_ event: AlertEvent) async {
        // 二次检查：仅在 .authorized 时才投递
        let status = await currentAuthorizationStatus()
        guard status == .authorized || status == .provisional else {
            logger.debug("skip notification: not authorized (status=\(status.rawValue, privacy: .public))")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "QuotaMonitor - \(event.provider.displayName) 配额告警"
        content.body = body(for: event)
        content.sound = event.level == .danger ? .defaultCritical : .default
        content.categoryIdentifier = "QUOTA_ALERT"
        content.userInfo = [
            "provider": event.provider.rawValue,
            "level": event.level.rawValue,
            "percent": Int(event.usedPercent)
        ]
        content.threadIdentifier = "quota.\(event.provider.rawValue)"

        // 立即投递
        let request = UNNotificationRequest(
            identifier: identifier(for: event),
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            logger.info("[\(event.provider.rawValue, privacy: .public)] notification sent: \(event.level.displayName, privacy: .public)")
        } catch {
            logger.error("add notification failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 批量投递
    public func sendAll(_ events: [AlertEvent]) async {
        for event in events {
            await send(event)
        }
    }

    // MARK: - 私有

    private func body(for event: AlertEvent) -> String {
        let pct = String(format: "%.0f", event.usedPercent)
        switch event.level {
        case .warning:
            return "\(event.provider.displayName) 已用 \(pct)%，请注意配额消耗"
        case .critical:
            return "\(event.provider.displayName) 已用 \(pct)%，接近上限，建议停止消耗"
        case .danger:
            return "\(event.provider.displayName) 已用 \(pct)%，配额即将耗尽"
        case .none:
            return ""
        }
    }

    /// 通知 ID：同窗口同等级发同一条（用户看到"已读"语义），更新则替换
    private func identifier(for event: AlertEvent) -> String {
        "qm.\(event.provider.rawValue).\(event.windowFingerprint).\(event.level.rawValue)"
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// 即使 app 在前台也显示通知
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // 用户点击通知：打开设置面板
        let userInfo = response.notification.request.content.userInfo
        if let providerRaw = userInfo["provider"] as? String,
           ProviderKind(rawValue: providerRaw) != nil {
            Task { @MainActor in
                SettingsWindowController.shared.show()
            }
        }
        completionHandler()
    }
}
