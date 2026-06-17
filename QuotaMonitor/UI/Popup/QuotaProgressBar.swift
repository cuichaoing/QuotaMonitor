//
//  QuotaProgressBar.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  极简进度条：6pt 高，圆角 3pt，颜色随阈值变化
//

import SwiftUI

public struct QuotaProgressBar: View {
    public let percent: Double   // 0-100，已用百分比

    public init(percent: Double) {
        self.percent = percent
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
                    .fill(SemanticColors.color(for: percent))
                    .frame(width: geometry.size.width * CGFloat(min(100, percent) / 100), height: 6)
                    .cornerRadius(3)
            }
        }
        .frame(height: 6)
    }
}
