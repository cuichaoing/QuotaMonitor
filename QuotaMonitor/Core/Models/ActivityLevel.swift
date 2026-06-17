//
//  ActivityLevel.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  智能节流系统使用的活动级别枚举（独立模块，避免循环依赖）
//

import Foundation

/// 系统活动级别，决定智能节流的轮询间隔。
///
/// - L0 `.active`：用户正在活跃编码（IDE 焦点）   -> 30s
/// - L1 `.normal`：用户在场，无编码行为            -> 1m
/// - L2 `.idle`：长时间无输入，屏幕常亮             -> 5m
/// - L3 `.sleeping`：系统休眠                       -> 暂停
public enum ActivityLevel: Int, CaseIterable, Sendable, Comparable {
    case active = 0
    case normal = 1
    case idle = 2
    case sleeping = 3

    public static func < (lhs: ActivityLevel, rhs: ActivityLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 当前级别对应的轮询间隔（秒）。
    /// 注意：`.sleeping` 实际由 SmartRefreshScheduler 在 runLoop 中跳过而非真正等待。
    public var refreshIntervalSeconds: TimeInterval {
        switch self {
        case .active:    return 30
        case .normal:    return 60
        case .idle:      return 300
        case .sleeping:  return 3_600
        }
    }

    /// 是否应该跳过本轮抓取（休眠期）。
    public var shouldSkipTick: Bool {
        self == .sleeping
    }

    public var displayName: String {
        switch self {
        case .active:    return "Active"
        case .normal:    return "Normal"
        case .idle:      return "Idle"
        case .sleeping:  return "Sleeping"
        }
    }
}
