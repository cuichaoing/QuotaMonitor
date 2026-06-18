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

        let sorted = ProviderKind.allCases.sorted(by: { $0.sortOrder < $1.sortOrder })
        for (i, kind) in sorted.enumerated() {
            if i > 0 {
                attributed.append(NSAttributedString(
                    string: "  ",
                    attributes: [.foregroundColor: labelColor]
                ))
            }
            // 字母 K/M/G（labelColor，常规字重）
            attributed.append(NSAttributedString(
                string: kind.shortName,
                attributes: [.foregroundColor: labelColor, .font: monoBoldFont]
            ))
            // 数字 / "!" / "--"（语义色，等宽字重）
            // [BUG-2026-06-18-01 根因 B] 用 MenuBarSegment.resolve 统一决策：
            // error 优先 → "!" 红色（与 Popup "离线" 红标对齐），不再只看 snapshot
            //   而显示陈旧的旧百分比，杜绝状态栏与 Popup 的成功/失败状态分裂。
            let numberText: String
            let numberColor: NSColor
            switch MenuBarSegment.resolve(snapshot: snapshots[kind], error: appState.store.errors[kind]) {
            case .failed:
                numberText = " !"
                numberColor = .systemRed
            case .value(let display, let raw):
                numberText = " \(display)"
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
