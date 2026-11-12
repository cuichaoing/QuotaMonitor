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

    /// 根据已用百分比返回语义颜色（三色）：
    ///   - 绿（normal）：安全范围（< 75%）
    ///   - 橙（critical）：超过健康阈值、提醒风险，但还能用（75% ~ 100%）
    ///   - 红（error）：额度耗尽、完全不可用（>= 100%，剩余 0%）
    public static func color(for usedPercent: Double) -> Color {
        if usedPercent >= 100 { return error }      // 耗尽
        if usedPercent >= 75  { return critical }   // 超健康阈值（警告，还能用）
        return normal                                // 安全
    }
}
