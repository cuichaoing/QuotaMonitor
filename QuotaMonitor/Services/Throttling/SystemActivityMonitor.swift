//
//  SystemActivityMonitor.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  系统活跃度监视器：监听休眠/唤醒/焦点应用
//

import Foundation
import AppKit

public final class SystemActivityMonitor: @unchecked Sendable {
    public static let shared = SystemActivityMonitor()

    /// 活动级别流（cold signal），订阅后开始监听
    public var levelStream: AsyncStream<ActivityLevel> {
        AsyncStream { continuation in
            self.continuation = continuation
            startMonitoring()
            continuation.onTermination = { [weak self] _ in
                self?.stopMonitoring()
            }
        }
    }

    private var continuation: AsyncStream<ActivityLevel>.Continuation?
    private var observers: [NSObjectProtocol] = []

    /// 常见 IDE Bundle ID（可由用户在 Settings 中扩展）
    private var ideBundleIDs: Set<String> = [
        "com.microsoft.VSCode",
        "com.apple.dt.Xcode",
        "com.google.Chrome",
        "com.sublimetext.4",
        "com.sublimetext.3",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.goland",
        "com.jetbrains.rider",
        "com.jetbrains.WebStorm",
        "com.jetbrains.CLion",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.RubyMine",
        "dev.zed.Zed",
        "com.todesktop.kych.support",   // Cursor
        "com.todesktop.kych",            // Cursor (alt)
        "com.linear",                    // Linear（高频操作也算 active）
        "com.figma.Desktop"
    ]

    private init() {}

    private func startMonitoring() {
        let center = NSWorkspace.shared.notificationCenter

        // 1. 系统休眠 -> sleeping
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.continuation?.yield(.sleeping)
        })

        // 2. 系统唤醒 -> active（保守策略：唤醒后先查一次）
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.continuation?.yield(.active)
        })

        // 3. 屏幕锁定/解锁（NSWorkspace.screensDidSleep 包含屏保进入）
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.continuation?.yield(.idle)
        })

        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.continuation?.yield(.active)
        })

        // 4. 应用焦点切换
        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleID = app.bundleIdentifier else { return }
            let level: ActivityLevel = self?.isIDE(bundleID) == true ? .active : .normal
            self?.continuation?.yield(level)
        })
    }

    private func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        for o in observers {
            center.removeObserver(o)
        }
        observers.removeAll()
    }

    private func isIDE(_ bundleID: String) -> Bool {
        if ideBundleIDs.contains(bundleID) { return true }
        if bundleID.hasPrefix("com.jetbrains.") { return true }
        if bundleID.hasPrefix("dev.zed.") { return true }
        return false
    }

    // MARK: - IDE bundle 列表可由用户扩展

    public func addIDEBundleID(_ bundleID: String) {
        ideBundleIDs.insert(bundleID)
    }

    public func removeIDEBundleID(_ bundleID: String) {
        ideBundleIDs.remove(bundleID)
    }
}
