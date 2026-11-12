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
        let baiduMarker = kind == .baidu
            ? quota?.primaryWindow.map { BaiduUsageParser.expectedPercent(resetAt: $0.resetAt, now: Date()) }
            : nil

        return VStack(alignment: .leading, spacing: Spacing.sm) {
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
                        .foregroundColor(titleColor(raw: raw, marker: baiduMarker))
                } else {
                    Text("--")
                        .font(Typography.heading)
                        .foregroundColor(SemanticColors.secondary)
                }
            }

            // 进度条
            if let window = quota?.primaryWindow {
                QuotaProgressBar(percent: window.usedPercent, markerPercent: baiduMarker)
                CountdownLabel(resetAt: window.resetAt)

                // 副窗口：7 天限额进度条（带「日均应达」参考线，参考千帆算法）
                if let weekly = quota?.weeklyWindow {
                    HStack(spacing: Spacing.xs) {
                        Text(weekly.displayName)
                            .font(Typography.caption)
                            .foregroundColor(SemanticColors.secondary)
                        QuotaProgressBar(
                            percent: weekly.usedPercent,
                            markerPercent: weekly.expectedPercentByElapsedPeriod(periodSeconds: 7 * 24 * 3600)
                        )
                        Text("\(Int(weekly.usedPercent.rounded()))%")
                            .font(Typography.caption.monospacedDigit())
                            .foregroundColor(SemanticColors.secondary)
                    }
                }
            } else if let error = error {
                Text(error.localizedDescription)
                    .font(Typography.caption)
                    .foregroundColor(SemanticColors.secondary)
                    .lineLimit(2)
            } else {
                Text(kind == .gemini ? "未登录网页版（设置 → 登录）" : "未配置 API Key")
                    .font(Typography.caption)
                    .foregroundColor(SemanticColors.secondary)
            }
        }
        .padding(Spacing.sm)
        .background(SemanticColors.cardBackground)
        .cornerRadius(8)
    }

    /// 标题百分比数字颜色：耗尽恒红；有日均标记时按「是否超参考线」二值着色，与进度条一致。
    private func titleColor(raw: Double, marker: Double?) -> Color {
        if raw >= 100 { return SemanticColors.error }   // 耗尽 → 红
        if let marker {
            return raw > marker ? SemanticColors.critical : SemanticColors.normal
        }
        return SemanticColors.color(for: raw)
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
        case .sessionMissing:  return "未登录"
        case .sessionExpired:  return "登录过期"
        }
    }
}
