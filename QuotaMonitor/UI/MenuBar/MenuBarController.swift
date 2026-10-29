//
//  MenuBarController.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  状态栏控制器：NSStatusItem + NSPopover + NSHostingView 桥接 SwiftUI
//

import AppKit
import SwiftUI
import Combine

/// 状态栏单个平台的显示决策（纯逻辑，无 AppKit / actor 依赖，可单测）。
/// 修复 BUG-2026-06-18-01 根因 B：状态栏此前只读 snapshots、忽略 errors，
/// 导致某平台失败时状态栏仍显示旧百分比或 "--"，与 Popup 的 "离线" 红标不一致。
public enum MenuBarSegment: Equatable {
    /// 本轮抓取失败 → 状态栏显示 "!"
    case failed
    /// 成功 → 显示百分比（displayPercent 四舍五入；rawPercent 原始值用于配色阈值判定）
    case value(displayPercent: Int, rawPercent: Double)
    /// 无数据 → 显示 "--"
    case placeholder

    /// 决策优先级：error > 成功快照 > 占位
    public static func resolve(snapshot: ProviderQuota?, error: QuotaError?) -> MenuBarSegment {
        if error != nil { return .failed }
        if let snap = snapshot, let raw = snap.primaryUsedPercent {
            return .value(displayPercent: snap.displayPercent ?? 0, rawPercent: raw)
        }
        return .placeholder
    }
}

/// 状态栏标题的渲染方案（纯逻辑，无 AppKit 依赖，可单测）。
/// [v1.1.1] 用户需求：
///   1. 全部配额都是绿色时 → 状态栏只显示绿色的数字（安静模式，去掉 K/M/G/Z 字母）
///   2. 有平台进入红色档（≥ 危险阈值，通常是打满 100%）→ 该数字后加括号倒计时
///      （例：`K 100 (1h56m)`），倒计时由该平台的窗口重置时刻算出
public struct MenuBarTitlePlan: Equatable {
    public enum Item: Equatable {
        /// 正常数值（isExhausted = 进入红色档，需要附倒计时）
        case value(kind: ProviderKind, displayPercent: Int, rawPercent: Double, isExhausted: Bool)
        /// 抓取失败
        case failed(kind: ProviderKind)
        /// 无数据
        case placeholder(kind: ProviderKind)
    }

    public let items: [Item]
    /// 安静模式：全部平台都是绿色 → 只渲染数字
    public let quiet: Bool

    public init(
        snapshots: [ProviderKind: ProviderQuota],
        errors: [ProviderKind: QuotaError],
        warningThreshold: Double,
        dangerThreshold: Double
    ) {
        let sorted = ProviderKind.allCases.sorted { $0.sortOrder < $1.sortOrder }
        var built: [Item] = []
        for kind in sorted {
            let segment = MenuBarSegment.resolve(snapshot: snapshots[kind], error: errors[kind])
            switch segment {
            case .value(let display, let raw):
                built.append(.value(
                    kind: kind,
                    displayPercent: display,
                    rawPercent: raw,
                    isExhausted: raw >= dangerThreshold))
            case .failed:
                built.append(.failed(kind: kind))
            case .placeholder:
                built.append(.placeholder(kind: kind))
            }
        }
        self.items = built

        // 全绿才安静：任何失败 / 占位 / 非绿数值都会让字母回归
        self.quiet = built.allSatisfy { item in
            if case .value(_, _, let raw, let exhausted) = item {
                return raw < warningThreshold && !exhausted
            }
            return false
        }
    }

    /// 紧凑倒计时文案：1h56m / 45m / 12s
    public static func compactDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))m" : "\(hours)h"
        }
        if minutes > 0 { return "\(minutes)m" }
        return "\(secs)s"
    }
}

@MainActor
public final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let appState: AppState
    private var eventMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []

    public init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        setupStatusItem()
        setupPopover()
        setupEventMonitor()
        observeState()
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        // 状态栏图标：使用 SF Symbol 作为模板图，保持与系统状态栏一致的单色风格。
        // 左侧图标提供应用识别入口，右侧 K/M/G 数字保留数据密度。
        if let icon = NSImage(
            systemSymbolName: "chart.bar.fill",
            accessibilityDescription: "QuotaMonitor"
        ) {
            icon.isTemplate = true
            button.image = icon
            button.imagePosition = .imageLeft
        }
        button.toolTip = "QuotaMonitor - 点击查看"
        button.target = self
        button.action = #selector(handleClick(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // 立刻渲染一次初始 title（让用户看到 app 已就位 + K M G 占位）
        refreshStatusItemTitle()
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 360, height: 480)
        popover.contentViewController = NSHostingController(
            rootView: PopupView(appState: appState)
        )
    }

    private func setupEventMonitor() {
        // 点击 popover 外部自动关闭
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            guard let self = self else { return }
            if self.popover.isShown {
                self.popover.performClose(nil)
            }
        }
    }

    private func observeState() {
        // 用 Combine 监听 QuotaStore 变化，触发状态栏文本刷新。
        // [关键 v1.0.6] 用 $snapshots 而不是 objectWillChange：
        //   objectWillChange 在 @Published 的 willSet 触发，此时 snapshots 新值尚未写入，
        //   导致状态栏读到上一周期的旧快照、与 popup 显示不一致（状态栏滞后一个刷新周期）。
        //   $snapshots 在 didSet 后 send，读到的是当前快照。
        appState.store.$snapshots
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshStatusItemTitle()
            }
            .store(in: &cancellables)

        // 监听 SettingsStore 的 3 个阈值属性。
        // 【关键】用 $publisher 而不是 objectWillChange：
        //   objectWillChange 在 willSet 触发，新值还没写入；
        //   $publisher 在 didSet 后 send，新值已稳定。
        // slider 拖动时立即重绘，无 1 帧滞后。
        let s = appState.settings
        Publishers.Merge3(
            s.$warningThreshold.dropFirst().map { _ in () },
            s.$criticalThreshold.dropFirst().map { _ in () },
            s.$dangerThreshold.dropFirst().map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshStatusItemTitle()
        }
        .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc private func handleClick(_ sender: AnyObject?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "手动刷新", action: #selector(menuRefresh), keyEquivalent: "r")
        menu.addItem(withTitle: "设置...", action: #selector(menuOpenSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "导出诊断日志", action: #selector(menuExportDiag), keyEquivalent: "d")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // 恢复左键 popover
    }

    @objc private func menuRefresh() {
        Task { await appState.refresh() }
    }

    @objc private func menuOpenSettings() {
        SettingsWindowController.shared.show()
    }

    @objc private func menuQuit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func menuExportDiag() {
        // 导出脱敏诊断 JSON 到 ~/Downloads + 剪贴板，并在 Finder 定位文件
        if let url = appState.exportDiagnostics().url {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    // MARK: - Title Refresh

    private func refreshStatusItemTitle() {
        guard let button = statusItem.button else { return }
        let snapshots = appState.store.snapshots

        // 紧凑格式："K 35 M 60 G 12"
        // 任一平台缺失时显示 "--"
        //
        // 设计：
        //   - 字母 K/M/G 用 .labelColor（dark mode 白 / light mode 黑），永远清晰
        //   - 数字用语义色（绿/黄/橙/红）传达风险等级
        //   - 数字用等宽字体，避免宽度抖动
        //   - 不用 contentTintColor：它会同时染 image 和 title，无法分开控制
        let labelColor = NSColor.labelColor
        let monoFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let monoBoldFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let attributed = NSMutableAttributedString()
        attributed.append(NSAttributedString(
            string: "  ",
            attributes: [.foregroundColor: labelColor]
        ))

        // [v1.1.1] 渲染方案（纯逻辑，见 MenuBarTitlePlan）：
        //   - 全绿 → 安静模式：只显示绿色数字，不带 K/M/G/Z 字母
        //   - 非全绿 → 字母 + 数字；红色档数字后附括号倒计时（还有多久重置）
        let plan = MenuBarTitlePlan(
            snapshots: snapshots,
            errors: appState.store.errors,
            warningThreshold: appState.settings.warningThreshold,
            dangerThreshold: appState.settings.dangerThreshold)

        for (i, item) in plan.items.enumerated() {
            if i > 0 {
                attributed.append(NSAttributedString(
                    string: "  ",
                    attributes: [.foregroundColor: labelColor]
                ))
            }
            // 字母 K/M/G/Z（安静模式下省略；labelColor，常规字重）
            if !plan.quiet {
                let letter = " " + kindLetter(item)
                attributed.append(NSAttributedString(
                    string: letter,
                    attributes: [.foregroundColor: labelColor, .font: monoBoldFont]
                ))
            }
            // 数字 / "!" / "--"（语义色，等宽字重）
            // [BUG-2026-06-18-01 根因 B] 用 MenuBarSegment.resolve 统一决策：
            // error 优先 → "!" 红色（与 Popup "离线" 红标对齐），不再只看 snapshot
            //   而显示陈旧的旧百分比，杜绝状态栏与 Popup 的成功/失败状态分裂。
            let numberText: String
            let numberColor: NSColor
            switch item {
            case .failed:
                numberText = " !"
                numberColor = .systemRed
            case .value(let kind, let display, let raw, let isExhausted):
                var text = " \(display)"
                if isExhausted, let resetAt = snapshots[kind]?.primaryWindow?.resetAt {
                    let remain = resetAt.timeIntervalSinceNow
                    if remain > 0 {
                        text += " (\(MenuBarTitlePlan.compactDuration(remain)))"
                    }
                }
                numberText = text
                numberColor = Self.nsColor(for: raw, settings: appState.settings)
            case .placeholder:
                numberText = " --"
                numberColor = NSColor.tertiaryLabelColor
            }
            attributed.append(NSAttributedString(
                string: numberText,
                attributes: [.foregroundColor: numberColor, .font: monoFont]
            ))
        }
        button.attributedTitle = attributed
    }

    /// 取平台字母（安静模式下不渲染）
    private func kindLetter(_ item: MenuBarTitlePlan.Item) -> String {
        switch item {
        case .value(let kind, _, _, _): return kind.shortName
        case .failed(let kind): return kind.shortName
        case .placeholder(let kind): return kind.shortName
        }
    }

    /// 把 SwiftUI SemanticColors 映射到 NSColor。
    /// 用 .systemGreen/.systemYellow 等系统色，让 macOS 在 dark/light 模式下都自动调整亮度。
    /// 阈值从 SettingsStore 读取，用户在设置面板拖动 slider 立即生效。
    /// - Parameters:
    ///   - usedPercent: 平台已用百分比（0-100）
    ///   - settings: SettingsStore（提供 warning/critical/danger 阈值）
    private static func nsColor(for usedPercent: Double, settings: SettingsStore) -> NSColor {
        let warn = settings.warningThreshold
        let crit = settings.criticalThreshold
        let dang = settings.dangerThreshold
        switch usedPercent {
        case ..<warn:       return .systemGreen
        case warn..<crit:   return .systemYellow
        case crit..<dang:   return .systemOrange
        default:            return .systemRed
        }
    }
}

// MARK: - Notification helper (deprecated, kept for future use)

public extension Notification.Name {
    static let quotamonitorStateChanged = Notification.Name("quotamonitor.stateChanged")
}
