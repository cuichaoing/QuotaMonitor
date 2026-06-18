//
//  DiagHistoryStore.swift
//  QuotaMonitor
//
//  诊断轨迹 ring buffer：存最近若干次刷新的精简结果，供"导出诊断日志"附带。
//

import Foundation

/// 单个平台一次刷新的精简结果（诊断用，不含 raw）。
public enum DiagProviderOutcome: Sendable, Equatable {
    case ok(usedPercent: Double)
    case error(type: String)
}

/// 一次刷新的轨迹条目。
public struct DiagEntry: Sendable, Equatable {
    public let at: Date
    public let results: [ProviderKind: DiagProviderOutcome]

    public init(at: Date, results: [ProviderKind: DiagProviderOutcome]) {
        self.at = at
        self.results = results
    }
}

/// 非 @MainActor：不直接驱动 UI（非 ObservableObject），只在 AppState（@MainActor）单线程使用。
public final class DiagHistoryStore {
    /// 硬上限：最多保留 20 条（导出时再按时间窗过滤）
    public static let cap = 20

    private var entries: [DiagEntry] = []

    public init() {}

    public func append(_ entry: DiagEntry) {
        entries.append(entry)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
    }

    /// 取截止时间之后的条目（导出时用 5 分钟窗口调用）
    public func recent(since cutoff: Date) -> [DiagEntry] {
        entries.filter { $0.at >= cutoff }
    }

    /// 测试/调试用
    public var allEntries: [DiagEntry] { entries }
}
