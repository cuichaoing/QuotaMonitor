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

/// 数据平滑决策的记录（诊断用，v1.0.10）。
/// `applySmoothing` 保留旧值时填充：`applied = true` + `rawUsedPercent` = 本次被丢弃的真实值。
/// 让诊断 JSON 能直接看出「展示值是被平滑保留的旧值」，而非靠 usedPercent vs percentage 反差推断。
public struct SmoothingInfo: Sendable, Equatable {
    public let applied: Bool
    public let rawUsedPercent: Double?
    public init(applied: Bool, rawUsedPercent: Double? = nil) {
        self.applied = applied
        self.rawUsedPercent = rawUsedPercent
    }
}

public struct ProviderQuota: @unchecked Sendable, Equatable {
    public let provider: ProviderKind
    public let capturedAt: Date

    /// 5 小时滚动窗口（主窗口）
    public let primaryWindow: QuotaWindow?

    /// 24 小时 / 7 天周限制（部分平台提供，nil 表示未知）
    public let weeklyWindow: QuotaWindow?

    /// 服务端返回的原始 raw payload（调试 / 持久化用）
    public let raw: [String: Any]?

    /// 数据平滑决策记录（诊断用）；nil = 未被平滑。详见 `SmoothingInfo`。
    public let smoothing: SmoothingInfo?

    public init(
        provider: ProviderKind,
        capturedAt: Date = Date(),
        primaryWindow: QuotaWindow?,
        weeklyWindow: QuotaWindow? = nil,
        raw: [String: Any]? = nil,
        smoothing: SmoothingInfo? = nil
    ) {
        self.provider = provider
        self.capturedAt = capturedAt
        self.primaryWindow = primaryWindow
        self.weeklyWindow = weeklyWindow
        self.raw = raw
        self.smoothing = smoothing
    }

    public var primaryUsedPercent: Double? {
        primaryWindow?.usedPercent
    }

    public var primaryRemainingPercent: Double? {
        primaryWindow?.remainingPercent
    }

    /// UI 显示用的整数百分比（四舍五入，.5 向上）。
    /// 状态栏、popup 等所有展示位统一引用它，杜绝 Int() 截断与 String(format:"%.0f") 四舍五入混用
    /// 导致的显示分裂（v1.0.6 修复）。
    /// [!] 颜色阈值判定仍用原始 Double 的 primaryUsedPercent，避免阈值边界颜色错位。
    public var displayPercent: Int? {
        primaryUsedPercent.map { Int($0.rounded(.toNearestOrAwayFromZero)) }
    }

    /// 用于去重状态机的窗口指纹（同窗口去重 / 平滑防抖）。
    /// [v1.0.9 / BUG-2026-06-19-01] 锚定服务端真实窗口的 resetAt，而非抓取时刻。
    /// 旧实现用 capturedAt/18000 机械切 5h 桶，与服务端真实窗口相位错位：
    /// 真实窗口在桶内重置时指纹不变，被 applySmoothing 误判为「同窗口倒退」而卡住旧值。
    /// 新语义：同一 resetAt = 同一窗口（防抖 / 告警去重生效）；
    ///         服务端窗口重置 → resetAt 变 → 指纹变 → 平滑跳过 → 接受真实新值。
    /// resetAt 取整到分钟，吸收服务端毫秒级抖动；无窗口时退化为 "<kind>-0"。
    public var windowFingerprint: String {
        let resetEpoch = Int(primaryWindow?.resetAt.timeIntervalSince1970 ?? 0) / 60
        return "\(provider.rawValue)-\(resetEpoch)"
    }

    // MARK: - Equatable

    /// 自定义 Equatable：raw 是 [String: Any] 不可比较，仅比较关键字段
    public static func == (lhs: ProviderQuota, rhs: ProviderQuota) -> Bool {
        lhs.provider == rhs.provider &&
        lhs.capturedAt == rhs.capturedAt &&
        lhs.primaryWindow == rhs.primaryWindow &&
        lhs.weeklyWindow == rhs.weeklyWindow &&
        lhs.smoothing == rhs.smoothing
    }
}
