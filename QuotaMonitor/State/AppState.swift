//
//  AppState.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  应用顶层状态：编排 NetworkingService + SmartRefreshScheduler + QuotaStore
//

import Foundation
import SwiftUI
import AppKit
import os

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    public let store = QuotaStore.shared
    public let settings: SettingsStore
    public let scheduler: SmartRefreshScheduler

    private let networking = NetworkingService.shared
    private let alertStateMachine = AlertStateMachine()
    private lazy var notifications = NotificationManager.shared
    private let bark = BarkClient()
    private let logger = Logger(subsystem: "app.quotamonitor", category: "AppState")

    /// 诊断轨迹 ring buffer（refresh 时追加，exportDiagnostics 时读取）
    public let diagHistory = DiagHistoryStore()

    public init(settings: SettingsStore = .shared) {
        self.settings = settings
        let monitor = SystemActivityMonitor.shared
        self.scheduler = SmartRefreshScheduler(networking: networking, activityMonitor: monitor)
        scheduler.onTick = { [weak self] in
            await self?.refresh()
        }
    }

    // MARK: - Lifecycle

    /// 应用启动时调用一次
    public func bootstrap() {
        logger.info("AppState bootstrap")
        scheduler.start()

        // 异步：请求通知权限 + 第一次刷新
        Task {
            _ = await notifications.requestPermission()
            await refresh()
        }
    }

    /// 优雅停机
    public func shutdown() {
        logger.info("AppState shutdown")
        scheduler.stop()
    }

    // MARK: - Refresh

    /// 主动触发一次刷新（UI 手动按钮 + 智能节流回调共用）
    public func refresh() async {
        store.setRefreshing(true)
        defer { store.setRefreshing(false) }

        // 从 SettingsStore 读取用户启用的平台（默认全部）
        let target = settings.enabledKinds()
        let results = await networking.fetchAll(target)
        var newSnapshots: [ProviderKind: ProviderQuota] = [:]
        var newErrors: [ProviderKind: QuotaError] = [:]

        for (kind, result) in results {
            switch result {
            case .success(let quota):
                newSnapshots[kind] = quota
            case .failure(let err):
                newErrors[kind] = err
            }
        }

        store.update(snapshots: newSnapshots, errors: newErrors)

        // 写诊断轨迹（精简：每平台 ok(pct) / err(type)）
        var outcomes: [ProviderKind: DiagProviderOutcome] = [:]
        for kind in target {
            if let q = newSnapshots[kind], let pct = q.primaryUsedPercent {
                outcomes[kind] = .ok(usedPercent: pct)
            } else if newErrors[kind] != nil {
                outcomes[kind] = .error(type: Self.diagErrorType(newErrors[kind]!))
            }
        }
        diagHistory.append(DiagEntry(at: Date(), results: outcomes))

        // 跑告警状态机
        let events = alertStateMachine.evaluate(
            snapshots: newSnapshots,
            thresholds: (
                warning: settings.warningThreshold,
                critical: settings.criticalThreshold,
                danger: settings.dangerThreshold
            )
        )

        // 本机系统通知
        if !events.isEmpty {
            await notifications.sendAll(events)
        }

        // Bark 推送（如果启用且已配置）
        if !events.isEmpty, let config = settings.barkConfig() {
            for event in events {
                let payload = BarkPayload(
                    title: "QuotaMonitor - \(event.provider.displayName)",
                    body: "已用 \(Int(event.usedPercent))%（\(event.level.displayName)）",
                    level: event.level
                )
                do {
                    try await bark.push(payload, using: config)
                } catch {
                    logger.error("Bark push failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        logger.info("refresh done: \(newSnapshots.count) ok, \(newErrors.count) failed, alerts=\(events.count)")
    }

    // MARK: - Diagnostics Export

    /// 一键导出当前诊断快照：JSON 写文件 + 复制剪贴板（供 AI 诊断）。
    public func exportDiagnostics() -> DiagExportResult {
        let now = Date()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let config = DiagConfig(
            enabled: settings.enabledKinds(),
            keyConfigured: Dictionary(uniqueKeysWithValues:
                ProviderKind.allCases.map { ($0, settings.keyState(for: $0) == .configured) }),
            warningThreshold: settings.warningThreshold,
            criticalThreshold: settings.criticalThreshold,
            dangerThreshold: settings.dangerThreshold
        )
        do {
            let data = try DiagnosticsExporter.export(
                snapshots: store.snapshots,
                errors: store.errors,
                history: diagHistory.recent(since: now.addingTimeInterval(-300)),
                config: config,
                appVersion: version,
                now: now)

            let df = DateFormatter()
            df.dateFormat = "yyyyMMdd-HHmmss"
            let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("QuotaMonitor-diag-\(df.string(from: now)).json")
            try data.write(to: url, options: .atomic)

            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(String(data: data, encoding: .utf8) ?? "", forType: .string)

            logger.info("diag exported to \(url.path, privacy: .public)")
            return DiagExportResult(url: url, copiedToPasteboard: true, error: nil)
        } catch {
            logger.error("diag export failed: \(error.localizedDescription, privacy: .public)")
            return DiagExportResult(url: nil, copiedToPasteboard: false, error: error.localizedDescription)
        }
    }

    /// QuotaError → 诊断轨迹用的类型字符串
    private static func diagErrorType(_ err: QuotaError) -> String {
        switch err {
        case .networkUnreachable: return "networkUnreachable"
        case .keyMissing: return "keyMissing"
        case .keyInvalid: return "keyInvalid"
        case .rateLimited: return "rateLimited"
        case .serverError: return "serverError"
        case .decodingFailed: return "decodingFailed"
        case .unknown: return "unknown"
        case .mockDisabled: return "mockDisabled"
        case .cancelled: return "cancelled"
        }
    }
}

/// 诊断导出结果（供 UI 提示）
public struct DiagExportResult: Sendable {
    public let url: URL?
    public let copiedToPasteboard: Bool
    public let error: String?

    public init(url: URL?, copiedToPasteboard: Bool, error: String?) {
        self.url = url
        self.copiedToPasteboard = copiedToPasteboard
        self.error = error
    }
}
