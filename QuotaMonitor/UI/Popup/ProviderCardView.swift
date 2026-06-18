//
//  ProviderCardView.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  单平台卡片：名称 + 已用百分比 + 进度条 + 倒计时
//

import SwiftUI

public struct ProviderCardView: View {
    public let kind: ProviderKind
    public let quota: ProviderQuota?
    public let error: QuotaError?

    public init(kind: ProviderKind, quota: ProviderQuota?, error: QuotaError?) {
        self.kind = kind
        self.quota = quota
        self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // 标题行
            HStack {
                Text(kind.displayName)
                    .font(Typography.heading)
                Spacer()
                if let error = error {
                    statusBadge(text: errorShortText(error), color: SemanticColors.error)
                } else if let display = quota?.displayPercent, let raw = quota?.primaryUsedPercent {
                    Text("\(display)%")
                        .font(Typography.heading)
                        .foregroundColor(SemanticColors.color(for: raw))
                } else {
                    Text("--")
                        .font(Typography.heading)
                        .foregroundColor(SemanticColors.secondary)
                }
            }

            // 进度条
            if let window = quota?.primaryWindow {
                QuotaProgressBar(percent: window.usedPercent)
                CountdownLabel(resetAt: window.resetAt)
            } else if let error = error {
                Text(error.localizedDescription)
                    .font(Typography.caption)
                    .foregroundColor(SemanticColors.secondary)
                    .lineLimit(2)
            } else {
                Text("未配置 API Key")
                    .font(Typography.caption)
                    .foregroundColor(SemanticColors.secondary)
            }
        }
        .padding(Spacing.sm)
        .background(SemanticColors.cardBackground)
        .cornerRadius(8)
    }

    @ViewBuilder
    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(Typography.caption)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func errorShortText(_ error: QuotaError) -> String {
        switch error {
        case .keyMissing:      return "无 Key"
        case .keyInvalid:      return "Key 错"
        case .rateLimited:     return "限流"
        case .networkUnreachable: return "离线"
        case .decodingFailed:  return "解析"
        case .serverError:     return "5xx"
        case .cancelled:       return "取消"
        case .mockDisabled:    return "mock"
        case .unknown:         return "?"
        }
    }
}
