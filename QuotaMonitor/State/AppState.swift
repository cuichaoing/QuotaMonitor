//
//  AppState.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  应用顶层状态：编排 NetworkingService + SmartRefreshScheduler + QuotaStore
//

import Foundation
import SwiftUI
import os

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    public let store = QuotaStore.shared
    public let settings: SettingsStore
    public let scheduler: SmartRefreshScheduler

    private let networking = NetworkingService.shared
    private let alertStateMachine = AlertStateMachine()
    private let notifications = NotificationManager.shared
    private let bark = BarkClient()
    private let logger = Logger(subsystem: "app.quotamonitor", category: "AppState")

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
        let monitor = SystemActivityMonitor.shared
        self.scheduler = SmartRefreshScheduler(networking: networking, activityMonitor: monitor)
        scheduler.onTick = { [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Lifecycle

    /// 应用启动时调用一次
    public func bootstrap() {
        logger.info("AppState bootstrap")
        scheduler.start()

        // 异步：请求通知权限 + 第一次刷新
        Task {
            _ = await notifications.requestPermission()
            await refresh()
        }
    }

    /// 优雅停机
    public func shutdown() {
        logger.info("AppState shutdown")
        scheduler.stop()
    }

    // MARK: - Refresh

    /// 主动触发一次刷新（UI 手动按钮 + 智能节流回调共用）
    public func refresh() async {
        store.setRefreshing(true)
        defer { store.setRefreshing(false) }

        // 从 SettingsStore 读取用户启用的平台（默认全部）
        let target = settings.enabledKinds()
        let results = await networking.fetchAll(target)
        var newSnapshots: [ProviderKind: ProviderQuota] = [:]
        var newErrors: [ProviderKind: QuotaError] = [:]

        for (kind, result) in results {
            switch result {
            case .success(let quota):
                newSnapshots[kind] = quota
            case .failure(let err):
                newErrors[kind] = err
            }
        }

        store.update(snapshots: newSnapshots, errors: newErrors)

        // 跑告警状态机
        let events = alertStateMachine.evaluate(
            snapshots: newSnapshots,
            thresholds: (
                warning: settings.warningThreshold,
                critical: settings.criticalThreshold,
                danger: settings.dangerThreshold
            )
        )

        // 本机系统通知
        if !events.isEmpty {
            await notifications.sendAll(events)
        }

        // Bark 推送（如果启用且已配置）
        if !events.isEmpty, let config = settings.barkConfig() {
            for event in events {
                let payload = BarkPayload(
                    title: "QuotaMonitor - \(event.provider.displayName)",
                    body: "已用 \(Int(event.usedPercent))%（\(event.level.displayName)）",
                    level: event.level
                )
                do {
                    try await bark.push(payload, using: config)
                } catch {
                    logger.error("Bark push failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        logger.info("refresh done: \(newSnapshots.count) ok, \(newErrors.count) failed, alerts=\(events.count)")
    }
}
