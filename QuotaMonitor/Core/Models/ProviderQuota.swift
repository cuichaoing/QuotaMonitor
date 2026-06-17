//
//  ProviderQuota.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  跨平台统一的配额快照
//

import Foundation

/// 跨平台统一的配额快照。
/// 关键设计：所有数值都是「绝对值」，UI 层再做归一化。
public struct ProviderQuota: @unchecked Sendable, Equatable {
    public let provider: ProviderKind
    public let capturedAt: Date

    /// 5 小时滚动窗口（主窗口）
    public let primaryWindow: QuotaWindow?

    /// 24 小时 / 7 天周限制（部分平台提供，nil 表示未知）
    public let weeklyWindow: QuotaWindow?

    /// 服务端返回的原始 raw payload（调试 / 持久化用）
    public let raw: [String: Any]?

    public init(
        provider: ProviderKind,
        capturedAt: Date = Date(),
        primaryWindow: QuotaWindow?,
        weeklyWindow: QuotaWindow? = nil,
        raw: [String: Any]? = nil
    ) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.primaryWindow = primaryWindow
        self.weeklyWindow = weeklyWindow
        self.raw = raw
    }

    public var primaryUsedPercent: Double? {
        primaryWindow?.usedPercent
    }

    public var primaryRemainingPercent: Double? {
        primaryWindow?.remainingPercent
    }

    /// 用于去重状态机的窗口指纹（同窗口去重）
    /// 公式：floor(epoch / 18000)，每 5h 一个 ID
    public var windowFingerprint: String {
        let epoch = Int(capturedAt.timeIntervalSince1970)
        return "\(provider.rawValue)-\(epoch / 18000)"
    }

    // MARK: - Equatable

    /// 自定义 Equatable：raw 是 [String: Any] 不可比较，仅比较关键字段
    public static func == (lhs: ProviderQuota, rhs: ProviderQuota) -> Bool {
        lhs.provider == rhs.provider &&
        lhs.capturedAt == rhs.capturedAt &&
        lhs.primaryWindow == rhs.primaryWindow &&
        lhs.weeklyWindow == rhs.weeklyWindow
    }
}
