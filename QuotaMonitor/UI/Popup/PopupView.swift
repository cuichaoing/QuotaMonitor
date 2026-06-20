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
    /// [BUG-2026-06-20-01] 单独把 store 暴露成 @ObservedObject，让 SwiftUI 订阅 store.objectWillChange。
    /// AppState.store 是 `let` 属性（不是 @Published），store.snapshots 变化不会触发 appState.objectWillChange，
    /// 仅靠 @ObservedObject var appState 订阅时，PopupView body 不会响应 store.snapshots 变化，
    /// 导致 Popup 数字卡在用户打开 Popup 那一刻、状态栏持续更新——形成"状态栏新、Pop 旧"的稳定分裂。
    @ObservedObject private var store: QuotaStore
    /// 诊断导出后的瞬时反馈（点击后显示 2 秒再清除）
    @State private var diagFeedback: String?

    public init(appState: AppState) {
        self.appState = appState
        self.store = appState.store
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // 标题行
            HStack {
                Text("QuotaMonitor")
                    .font(Typography.title)
                Spacer()
                if store.isRefreshing {
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
            if !store.hasAnySnapshot {
                onboardingHint
            }

            Divider()

            // 三平台卡片
            ForEach(ProviderKind.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { kind in
                ProviderCardView(
                    kind: kind,
                    quota: store.snapshots[kind],
                    error: store.errors[kind]
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

                if let last = store.lastRefreshAt {
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
