//
//  SemanticColors.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  语义化颜色：normal / warning / critical / error 四级
//  阈值规则：<75 normal, 75-90 warning, 90-99 critical, >=99 error
//

import SwiftUI

public enum SemanticColors {
    public static let normal = Color.green
    public static let warning = Color.yellow
    public static let critical = Color.orange
    public static let error = Color.red

    public static let barBackground = Color.gray.opacity(0.2)
    public static let cardBackground = Color.gray.opacity(0.08)
    public static let secondary = Color.secondary

    /// 根据已用百分比返回语义颜色
    public static func color(for usedPercent: Double) -> Color {
        switch usedPercent {
        case ..<75:    return normal
        case 75..<90:  return warning
        case 90..<99:  return critical
        default:       return error
        }
    }
}
