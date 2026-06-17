//
//  KeychainStoreType.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  Keychain 抽象协议（便于注入内存 mock）
//

import Foundation

public protocol KeychainStoreType: Sendable {
    func save(_ value: String, for provider: ProviderKind) throws
    func read(for provider: ProviderKind) throws -> String?
    func delete(for provider: ProviderKind) throws
    func exists(for provider: ProviderKind) -> Bool
}
