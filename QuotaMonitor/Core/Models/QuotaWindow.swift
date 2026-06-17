//
//  QuotaWindow.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  单个时间窗口的配额结构（5h / 24h / 7d）
//

import Foundation

public struct QuotaWindow: Sendable, Equatable {
    public let total: Double
    public let used: Double
    public let resetAt: Date
    public let displayName: String  // "5h", "24h", "7d"

    public init(total: Double, used: Double, resetAt: Date, displayName: String) {
        self.total = total
        self.used = used
        self.resetAt = resetAt
        self.displayName = displayName
    }

    public var remaining: Double {
        max(0, total - used)
    }

    /// 已用百分比（0-100）。当 total 未知（如 GLM 直接返回百分比）时，外部应保证 total=100, used=percent。
    public var usedPercent: Double {
        guard total > 0 else { return 0 }
        return min(100, (used / total) * 100.0)
    }

    /// 剩余百分比（0-100）
    public var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}
