//
//  Provider.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  平台协议：所有 Provider 实现的契约
//

import Foundation

/// 三大平台共用的查询协议。
/// 实现类只负责「单次查询」，并发/缓存/重试/平滑由 NetworkingService 统一调度。
public protocol Provider: Sendable {
    var kind: ProviderKind { get }

    /// 单次查询，不做重试，不做缓存。
    /// - Parameters:
    ///   - apiKey: 用户在 Keychain 中保存的 API Key
    ///   - client: 共享的 HTTP 客户端（用于复用连接 + 注入 mock）
    /// - Throws: QuotaError
    /// - Returns: 统一模型 ProviderQuota
    func fetchQuota(apiKey: String, using client: HTTPClient) async throws -> ProviderQuota
}
