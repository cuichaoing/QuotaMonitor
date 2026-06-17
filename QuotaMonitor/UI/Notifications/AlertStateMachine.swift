//
//  AlertStateMachine.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  告警状态机：3 级阈值 + 5h 窗口指纹去重
//
//  去重规则：
//   1. 同一 (provider, level) 在同一 5h 窗口内最多触发一次
//   2. 跨窗口自动重置
//   3. 等级"升级"视为新事件（warning -> critical 必须通知）
//

import Foundation
import os

/// 单次告警事件
public struct AlertEvent: Sendable, Equatable {
    public let provider: ProviderKind
    public let level: AlertLevel
    public let usedPercent: Double
    public let windowFingerprint: String
    public let timestamp: Date

    public init(provider: ProviderKind, level: AlertLevel, usedPercent: Double, windowFingerprint: String, timestamp: Date = Date()) {
        self.provider = provider
        self.level = level
        self.usedPercent = usedPercent
        self.windowFingerprint = windowFingerprint
        self.timestamp = timestamp
    }
}

public final class AlertStateMachine: @unchecked Sendable {
    /// 已通知的最高等级表：(provider, fingerprint) -> maxLevelSent
    /// 规则：同窗口同 provider 只发一次，等级升级才再发，降级不发
    private var maxLevelSent: [WindowKey: AlertLevel] = [:]
    private let lock = NSLock()
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Alerts")

    private struct WindowKey: Hashable {
        let provider: ProviderKind
        let fingerprint: String
    }

    public init() {}

    /// 喂入一次新快照，返回应该发出的告警事件列表（可能 0/1/2 个）
    /// - Parameter snapshots: 当前所有平台的最新快照
    /// - Parameter thresholds: 用户配置的 3 级阈值
    public func evaluate(
        snapshots: [ProviderKind: ProviderQuota],
        thresholds: (warning: Double, critical: Double, danger: Double)
    ) -> [AlertEvent] {
        let now = Date()
        var newEvents: [AlertEvent] = []

        for (kind, quota) in snapshots {
            guard let window = quota.primaryWindow else { continue }

            let level = AlertLevel.classify(
                usedPercent: window.usedPercent,
                warning: thresholds.warning,
                critical: thresholds.critical,
                danger: thresholds.danger
            )

            guard level != .none else { continue }

            if shouldFire(provider: kind, fingerprint: quota.windowFingerprint, newLevel: level) {
                let event = AlertEvent(
                    provider: kind,
                    level: level,
                    usedPercent: window.usedPercent,
                    windowFingerprint: quota.windowFingerprint,
                    timestamp: now
                )
                newEvents.append(event)
                markFired(provider: kind, fingerprint: quota.windowFingerprint, level: level)
                logger.info("[\(kind.rawValue, privacy: .public)] alert: \(level.displayName, privacy: .public) at \(Int(window.usedPercent), privacy: .public)%")
            }
        }

        return newEvents
    }

    /// 重置所有去重状态（用于调试 / 单元测试）
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        maxLevelSent.removeAll()
    }

    // MARK: - 内部

    /// 仅当"新高"时才发（首次发 .warning/.critical/.danger 都算首次）
    private func shouldFire(provider: ProviderKind, fingerprint: String, newLevel: AlertLevel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let key = WindowKey(provider: provider, fingerprint: fingerprint)
        guard let sent = maxLevelSent[key] else { return true }
        return newLevel > sent   // 升级才发，降级不发
    }

    private func markFired(provider: ProviderKind, fingerprint: String, level: AlertLevel) {
        lock.lock()
        defer { lock.unlock() }
        let key = WindowKey(provider: provider, fingerprint: fingerprint)
        if let sent = maxLevelSent[key] {
            maxLevelSent[key] = max(sent, level)
        } else {
            maxLevelSent[key] = level
        }
    }
}
