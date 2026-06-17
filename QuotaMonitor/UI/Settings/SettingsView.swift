//
//  SettingsView.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  设置面板：3 平台 Key 管理 + 阈值调节 + 刷新频率（高级）
//

import SwiftUI
import LocalAuthentication
import ServiceManagement

public struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    public init(settings: SettingsStore) {
        self.settings = settings
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack {
                Text("QuotaMonitor 设置")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.lg)
            .padding(.bottom, Spacing.md)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    providersSection
                    launchAtLoginSection
                    thresholdSection
                    barkSection
                    advancedSection
                }
                .padding(Spacing.lg)
            }

            Divider()

            // 底部按钮
            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.md)
        }
        .frame(width: 520, height: 700)
    }

    // MARK: - Providers

    private var providersSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("平台配置")
                .font(.headline)

            Text("填入 API Key 后启用该平台的配额监控")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(ProviderKind.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { kind in
                ProviderKeyRow(kind: kind, settings: settings)
            }
        }
    }

    // MARK: - LaunchAtLogin

    private var launchAtLoginSection: some View {
        LaunchAtLoginSection(settings: settings)
    }

    // MARK: - Thresholds

    private var thresholdSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("颜色阈值")
                .font(.headline)

            Text("已用百分比超过阈值时改变状态栏图标颜色")
                .font(.caption)
                .foregroundColor(.secondary)

            ThresholdSlider(
                label: "黄色警告",
                value: $settings.warningThreshold,
                range: 50...95,
                color: SemanticColors.warning
            )
            ThresholdSlider(
                label: "橙色严重",
                value: $settings.criticalThreshold,
                range: 80...98,
                color: SemanticColors.critical
            )
            ThresholdSlider(
                label: "红色危险",
                value: $settings.dangerThreshold,
                range: 95...100,
                color: SemanticColors.error
            )
        }
    }

    // MARK: - Bark 推送

    private var barkSection: some View {
        BarkSection(settings: settings)
    }

    // MARK: - Advanced

    @State private var showAdvanced = false

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            DisclosureGroup(isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text("刷新频率（秒）")
                        .font(.subheadline)
                    IntervalRow(label: "活跃", value: $settings.activeInterval, range: 10...300)
                    IntervalRow(label: "普通", value: $settings.normalInterval, range: 30...600)
                    IntervalRow(label: "空闲", value: $settings.idleInterval, range: 60...1800)
                }
                .padding(.top, Spacing.xs)
            } label: {
                Text("高级")
                    .font(.headline)
            }
        }
    }
}

// MARK: - BarkSection

private struct BarkSection: View {
    @ObservedObject var settings: SettingsStore
    @State private var keyInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Toggle(isOn: $settings.barkEnabled) {
                HStack {
                    Text("Bark 推送")
                        .font(.headline)
                    Text("(iOS)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            if settings.barkEnabled {
                Text("通过 Bark App 把告警推送到 iPhone（需 iOS 端安装 Bark）")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Text("服务器")
                        .frame(width: 60, alignment: .leading)
                        .font(.subheadline)
                    TextField("https://api.day.app", text: $settings.barkServer)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: Spacing.xs) {
                    SecureField("Device Key", text: $keyInput)
                        .textFieldStyle(.roundedBorder)

                    Button("保存", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(keyInput.isEmpty)

                    if settings.barkKeyState() == .configured {
                        Button("删除", role: .destructive, action: delete)
                            .buttonStyle(.bordered)
                    }
                }

                if settings.barkKeyState() == .configured {
                    Label("已配置", systemImage: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
        }
    }

    private func save() {
        do {
            try settings.saveBarkKey(keyInput)
            keyInput = ""
        } catch {
            // silently ignore (UI 无 toast，简单处理)
        }
    }

    private func delete() {
        settings.deleteBarkKey()
    }
}

// MARK: - ProviderKeyRow

private struct ProviderKeyRow: View {
    let kind: ProviderKind
    @ObservedObject var settings: SettingsStore
    @State private var keyInput: String = ""
    @State private var showKey: Bool = false
    @State private var isAuthenticating: Bool = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Toggle(isOn: bindingEnabled) {
                    Text(kind.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                }
                .toggleStyle(.checkbox)

                Spacer()

                if settings.keyState(for: kind) == .configured {
                    Label("已配置", systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }

            HStack(spacing: Spacing.xs) {
                Group {
                    if showKey {
                        TextField("sk-...", text: $keyInput)
                    } else {
                        SecureField("sk-...", text: $keyInput)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(!settings.enabledProviders.contains(kind))

                Button {
                    Task { await toggleVisibility() }
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .help(showKey ? "隐藏（再次显示需身份验证）" : "显示（需 macOS 身份验证）")
                .disabled(isAuthenticating)

                Button("保存", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(keyInput.isEmpty || !settings.enabledProviders.contains(kind))

                if settings.keyState(for: kind) == .configured {
                    Button("删除", role: .destructive, action: delete)
                        .buttonStyle(.bordered)
                }
            }

            if let err = error {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor))
        )
    }

    private var bindingEnabled: Binding<Bool> {
        Binding(
            get: { settings.enabledProviders.contains(kind) },
            set: { newValue in
                if newValue {
                    settings.enabledProviders.insert(kind)
                } else {
                    settings.enabledProviders.remove(kind)
                }
            }
        )
    }

    private func save() {
        do {
            try settings.saveKey(keyInput, for: kind)
            keyInput = ""
            error = nil
        } catch {
            self.error = "保存失败: \(error.localizedDescription)"
        }
    }

    private func delete() {
        do {
            try settings.deleteKey(for: kind)
            error = nil
        } catch {
            self.error = "删除失败: \(error.localizedDescription)"
        }
    }

    /// 切换 Key 可见性。
    /// 切到显示模式时：先要求 macOS 身份验证（Touch ID / Apple Watch / 系统密码），
    /// 验证通过后从 Keychain 读取明文，填到 keyInput，TextField 渲染。
    /// 切到隐藏模式时：清空 keyInput（避免 SecureField 内存里残留明文）。
    private func toggleVisibility() async {
        if showKey {
            // 已经在显示 → 切回隐藏，立即清空
            keyInput = ""
            showKey = false
            return
        }

        // 切到显示模式：先身份验证
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedReason = "显示 \(kind.displayName) 的 API Key"
        context.localizedCancelTitle = "取消"

        do {
            // .deviceOwnerAuthentication 支持 Touch ID / Apple Watch / 密码
            // 失败多次会自动 fallback 到系统密码输入框
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "显示 \(kind.displayName) 的 API Key"
            )
            if success {
                if let stored = try settings.readKey(for: kind) {
                    keyInput = stored
                    showKey = true
                } else {
                    error = "该平台尚未配置 Key"
                }
            }
        } catch {
            // 用户取消或验证失败 → 保持隐藏，不报错
        }
    }
}

// MARK: - ThresholdSlider

private struct ThresholdSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let color: Color

    /// 文本框缓冲（slider 拖动时不会让光标跳动）
    @State private var textValue: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
                .frame(width: 80, alignment: .leading)
                .font(.subheadline)
            Slider(value: $value, in: range, step: 1) {
                Text(label)  // a11y
            }
            // 可编辑数字框：直接输入更精确
            HStack(spacing: 2) {
                TextField("", text: $textValue)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 44)
                    .focused($isFocused)
                    .onSubmit { commit() }
                Text("%")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(width: 60, alignment: .trailing)
        }
        .onAppear { textValue = "\(Int(value))" }
        .onChange(of: value) { newValue in
            // slider 拖动时同步（仅在非编辑态，避免光标跳动）
            if !isFocused { textValue = "\(Int(newValue))" }
        }
        .onChange(of: isFocused) { focused in
            // 失焦时提交（避免用户改了一半就关掉窗口）
            if !focused { commit() }
        }
    }

    /// 把 textValue 解析为 Int，clamp 到 range，写回 value。
    /// 解析失败或越界时：恢复成当前 value 的字符串显示。
    private func commit() {
        let trimmed = textValue.trimmingCharacters(in: .whitespaces)
        if let intValue = Int(trimmed) {
            let clamped = min(max(Double(intValue), range.lowerBound), range.upperBound)
            value = clamped
            textValue = "\(Int(clamped))"
        } else {
            // 非法输入：恢复成 current value
            textValue = "\(Int(value))"
        }
    }
}

// MARK: - LaunchAtLoginSection

private struct LaunchAtLoginSection: View {
    @ObservedObject var settings: SettingsStore
    @State private var serviceStatus: SMAppService.Status = LoginItemManager.shared.status

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("启动")
                .font(.headline)

            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    Task { @MainActor in
                        await syncLaunchAtLogin(enabled: newValue)
                    }
                }
            )) {
                Text("登录时自动启动 QuotaMonitor")
            }
            .toggleStyle(.checkbox)

            HStack(spacing: Spacing.xs) {
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)

                Spacer()

                if serviceStatus == .requiresApproval {
                    Button("打开系统设置") {
                        LoginItemManager.shared.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusText: String {
        switch serviceStatus {
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要在系统设置 → 登录项中允许"
        case .notRegistered:
            return "未启用"
        case .notFound:
            return "状态异常"
        @unknown default:
            return "未知状态"
        }
    }

    private var statusColor: Color {
        switch serviceStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .secondary
        case .notFound: return .red
        @unknown default: return .secondary
        }
    }

    private func syncLaunchAtLogin(enabled: Bool) async {
        do {
            if enabled {
                try LoginItemManager.shared.register()
            } else {
                try LoginItemManager.shared.unregister()
            }
        } catch {
            // 注册失败时保持静默，UI 会显示实际状态
        }
        serviceStatus = LoginItemManager.shared.status
    }
}

// MARK: - IntervalRow

private struct IntervalRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack {
            Text(label)
                .frame(width: 60, alignment: .leading)
                .font(.subheadline)
            Slider(value: $value, in: range, step: 10)
            Text("\(Int(value))s")
                .font(.subheadline.monospacedDigit())
                .frame(width: 50, alignment: .trailing)
        }
    }
}
