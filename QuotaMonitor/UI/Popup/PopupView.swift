//
//  PopupView.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  状态栏下拉主面板：标题 + 3 平台卡片 + 底部状态
//

import SwiftUI

public struct PopupView: View {
    @ObservedObject public var appState: AppState
    /// 诊断导出后的瞬时反馈（点击后显示 2 秒再清除）
    @State private var diagFeedback: String?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // 标题行
            HStack {
                Text("QuotaMonitor")
                    .font(Typography.title)
                Spacer()
                if appState.store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                } else {
                    Button {
                        Task { await appState.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("手动刷新")
                }
            }

            // 首次启动引导
            if !appState.store.hasAnySnapshot {
                onboardingHint
            }

            Divider()

            // 三平台卡片
            ForEach(ProviderKind.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { kind in
                ProviderCardView(
                    kind: kind,
                    quota: appState.store.snapshots[kind],
                    error: appState.store.errors[kind]
                )
            }

            Divider()

            // 底部状态
            HStack {
                Button("设置") {
                    SettingsWindowController.shared.show()
                }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundColor(SemanticColors.secondary)
                .help("管理 API Key 和刷新频率")

                if let last = appState.store.lastRefreshAt {
                    Text("刷新于 \(last, style: .time)")
                        .font(Typography.caption)
                        .foregroundColor(SemanticColors.secondary)
                } else {
                    Text("等待首次刷新…")
                        .font(Typography.caption)
                        .foregroundColor(SemanticColors.secondary)
                }
                Spacer()
                Text("v\(appVersion)")
                    .font(Typography.caption)
                    .foregroundColor(SemanticColors.secondary)
                Button {
                    let r = appState.exportDiagnostics()
                    diagFeedback = (r.url != nil) ? "已导出+已复制" : "导出失败"
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        await MainActor.run { diagFeedback = nil }
                    }
                } label: {
                    Text(diagFeedback ?? "诊断")
                        .foregroundColor(diagFeedback == "导出失败" ? .red : SemanticColors.secondary)
                }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .help("导出当前诊断日志到下载文件夹并复制到剪贴板")
                Button("退出") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(Typography.caption)
                .foregroundColor(SemanticColors.secondary)
            }
        }
        .padding(Spacing.md)
        .frame(width: 340)
    }

    /// 首次启动引导：未配置任何 Key 时显示
    private var onboardingHint: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label("首次使用", systemImage: "sparkles")
                .font(.subheadline.weight(.medium))
                .foregroundColor(SemanticColors.warning)

            Text("点击\"设置\"填入至少一个平台的 API Key，即可开始监控配额。")
                .font(.caption)
                .foregroundColor(SemanticColors.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("打开设置") {
                SettingsWindowController.shared.show()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.1))
        )
    }

    /// 从 Info.plist 读取应用短版本号（例如 1.0.4）
    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
}
