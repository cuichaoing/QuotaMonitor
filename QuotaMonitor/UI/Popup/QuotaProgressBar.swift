//
//  QuotaProgressBar.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  极简进度条：6pt 高，圆角 3pt，颜色随阈值变化
//  可选竖线标记（markerPercent）：标记「当前时间按平均速度应到达的百分比」
//  存在标记时，颜色不看阈值，改为：未超标记 → 绿，超标记 → 橙（用超提醒）
//

import SwiftUI

public struct QuotaProgressBar: View {
    public let percent: Double          // 0-100，已用百分比
    public let markerPercent: Double?   // 竖线标记位置（0-100），nil 表示不画标记

    public init(percent: Double, markerPercent: Double? = nil) {
        self.percent = percent
        self.markerPercent = markerPercent
    }

    /// 填充色：耗尽（100%）恒红；有标记时按「是否超参考线」二值着色；无标记走三色阈值分级
    private var fillColor: Color {
        if percent >= 100 { return SemanticColors.error }   // 耗尽 → 红（不可用）
        if let marker = markerPercent {
            return percent > marker ? SemanticColors.critical : SemanticColors.normal
        }
        return SemanticColors.color(for: percent)
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 背景条
                Rectangle()
                    .fill(SemanticColors.barBackground)
                    .frame(height: 6)
                    .cornerRadius(3)

                // 已用条
                Rectangle()
                    .fill(fillColor)
                    .frame(width: geometry.size.width * CGFloat(min(100, max(0, percent)) / 100), height: 6)
                    .cornerRadius(3)

                // 竖线标记：当前时间按平均速度应到达的百分比
                if let marker = markerPercent, marker >= 0, marker <= 100 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.7))
                        .frame(width: 2, height: 12)
                        .offset(x: geometry.size.width * CGFloat(marker / 100) - 1)
                }
            }
        }
        .frame(height: 6)
    }
}