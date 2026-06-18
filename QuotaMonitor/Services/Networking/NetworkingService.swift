//
//  NetworkingService.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  三大平台配额查询的总调度器：
//   1. 并行抓取（withTaskGroup）
//   2. 智能缓存（actor 状态）
//   3. 数据平滑（防 MiniMax 被动流失）
//   4. 节流由 SmartRefreshScheduler 外部控制，本服务不感知
//

import Foundation
import os

public actor NetworkingService {
    public static let shared = NetworkingService()

    private let keychain: KeychainStoreType
    private let httpClient: HTTPClient
    private let providers: [ProviderKind: any Provider]
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Networking")
    private var lastSnapshot: [ProviderKind: ProviderQuota] = [:]

    public init(
        keychain: KeychainStoreType = KeychainStore.shared,
        httpClient: HTTPClient = .shared
    ) {
        self.keychain = keychain
        self.httpClient = httpClient
        self.providers = [
            .kimi:    KimiProvider(),
            .minimax: MiniMaxProvider(),
            .glm:     GLMProvider()
        ]
    }

    // MARK: - Public API

    /// 并行拉取所有已配置平台的最新配额。
    /// - Parameter kinds: nil = 全部 3 平台；指定则只查指定平台
    /// - Returns: 按 ProviderKind 分组的快照（含成功 / 失败）
    public func fetchAll(_ kinds: [ProviderKind]? = nil) async -> [ProviderKind: Result<ProviderQuota, QuotaError>] {
        let target = kinds ?? Array(providers.keys)

        return await withTaskGroup(of: (ProviderKind, Result<ProviderQuota, QuotaError>).self) { group in
            for kind in target {
                group.addTask { [self] in
                    let result = await fetchOne(kind)
                    return (kind, result)
                }
            }

            var results: [ProviderKind: Result<ProviderQuota, QuotaError>] = [:]
            for await (kind, result) in group {
                results[kind] = result
            }
            return results
        }
    }

    /// 拉取单个平台
    public func fetchOne(_ kind: ProviderKind) async -> Result<ProviderQuota, QuotaError> {
        do {
            guard let key = try keychain.read(for: kind), !key.isEmpty else {
                throw QuotaError.keyMissing(kind)
            }
            guard let provider = providers[kind] else {
                throw QuotaError.mockDisabled(kind)
            }
            let raw = try await provider.fetchQuota(apiKey: key, using: httpClient)
            let smoothed = applySmoothing(raw, kind: kind)
            self.lastSnapshot[kind] = smoothed
            return .success(smoothed)
        } catch let err as QuotaError {
            logger.error("[\(kind.rawValue, privacy: .public)] fetch failed: \(err.localizedDescription, privacy: .public)")
            return .failure(err)
        } catch _ as URLError {
            // 传输层失败（超时 / DNS / TLS / 断网等），归因到当前 provider。
            // [BUG-2026-06-18-01] 此前 HTTPClient 把 URLError 硬编码成 networkUnreachable(.kimi)，
            // 导致 MiniMax / GLM 的网络错误挂到 Kimi 名下。
            logger.error("[\(kind.rawValue, privacy: .public)] transport error -> networkUnreachable")
            return .failure(.networkUnreachable(kind))
        } catch {
            logger.error("[\(kind.rawValue, privacy: .public)] unknown error: \(error.localizedDescription, privacy: .public)")
            return .failure(.unknown(kind, underlying: error.localizedDescription))
        }
    }

    /// 取最近一次成功的快照（用于 UI 启动时的初始渲染）
    public func lastQuota(for kind: ProviderKind) -> ProviderQuota? {
        lastSnapshot[kind]
    }

    /// 取所有最近快照
    public func allLastQuotas() -> [ProviderKind: ProviderQuota] {
        lastSnapshot
    }

    // MARK: - Smoothing

    /// 【数据平滑】对治 MiniMax 被动流失
    /// 规则：同窗口指纹下，curWin.used 不能 < prevWin.used
    private func applySmoothing(_ quota: ProviderQuota, kind: ProviderKind) -> ProviderQuota {
        guard let prev = lastSnapshot[kind],
              let prevWin = prev.primaryWindow,
              let curWin = quota.primaryWindow,
              prev.windowFingerprint == quota.windowFingerprint else {
            return quota   // 新窗口或首次，无需平滑
        }

        if curWin.used < prevWin.used {
            // 倒退：保留上一次（可能是被动流失后回弹）
            logger.warning("[\(kind.rawValue, privacy: .public)] smoothing: cur.used < prev.used, retaining previous value")
            return ProviderQuota(
                provider: kind,
                capturedAt: quota.capturedAt,
                primaryWindow: prevWin,
                weeklyWindow: quota.weeklyWindow,
                raw: quota.raw
            )
        }
        return quota
    }
}
