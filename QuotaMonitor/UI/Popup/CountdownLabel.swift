//
//  CountdownLabel.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  倒计时标签：每 1s 刷新，SwiftUI relative time
//

import SwiftUI

public struct CountdownLabel: View {
    public let resetAt: Date

    @State private var now: Date = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    public init(resetAt: Date) {
        self.resetAt = resetAt
    }

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 9))
            Text("重置于 \(resetAt, style: .relative)")
            Text("·")
            Text(resetAt, style: .time)
        }
        .font(Typography.caption)
        .foregroundColor(SemanticColors.secondary)
        .onReceive(timer) { _ in
            now = Date()
        }
    }
}
