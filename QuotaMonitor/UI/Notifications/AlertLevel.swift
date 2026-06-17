//
//  AlertLevel.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  告警等级定义（3 级：warning / critical / danger）
//

import Foundation
import SwiftUI

public enum AlertLevel: Int, CaseIterable, Sendable, Comparable {
    case none = 0
    case warning = 1
    case critical = 2
    case danger = 3

    public static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .none:     return "正常"
        case .warning:  return "警告"
        case .critical: return "严重"
        case .danger:   return "危险"
        }
    }

    public var color: Color {
        switch self {
        case .none:     return SemanticColors.normal
        case .warning:  return SemanticColors.warning
        case .critical: return SemanticColors.critical
        case .danger:   return SemanticColors.error
        }
    }

    /// 根据 usedPercent 和阈值表确定告警等级
    public static func classify(usedPercent: Double, warning: Double, critical: Double, danger: Double) -> AlertLevel {
        if usedPercent >= danger    { return .danger }
        if usedPercent >= critical  { return .critical }
        if usedPercent >= warning   { return .warning }
        return .none
    }
}
