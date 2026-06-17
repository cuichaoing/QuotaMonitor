//
//  KeychainStore.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  Keychain Services 封装：API Key 硬件级加密存储
//

import Foundation
import Security

public final class KeychainStore: KeychainStoreType, @unchecked Sendable {
    public static let shared = KeychainStore()

    private let service: String
    private let accessGroup: String?

    public init(
        service: String = "app.quotamonitor.apikeys",
        accessGroup: String? = nil
    ) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Public API

    public func save(_ value: String, for provider: ProviderKind) throws {
        let account = provider.rawValue
        let data = Data(value.utf8)

        // 先尝试 update（处理已存在的情况）
        var query = baseQuery(account: account)
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)

        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            // 不存在，添加新条目
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw QuotaError.serverError(provider, statusCode: Int(addStatus), message: "Keychain add failed (OSStatus \(addStatus))")
            }
        default:
            throw QuotaError.serverError(provider, statusCode: Int(status), message: "Keychain update failed (OSStatus \(status))")
        }
    }

    public func read(for provider: ProviderKind) throws -> String? {
        var query = baseQuery(account: provider.rawValue)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let str = String(data: data, encoding: .utf8) else {
                return nil
            }
            return str
        case errSecItemNotFound:
            return nil
        default:
            throw QuotaError.serverError(provider, statusCode: Int(status), message: "Keychain read failed (OSStatus \(status))")
        }
    }

    public func delete(for provider: ProviderKind) throws {
        let query = baseQuery(account: provider.rawValue)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw QuotaError.serverError(provider, statusCode: Int(status), message: "Keychain delete failed (OSStatus \(status))")
        }
    }

    public func exists(for provider: ProviderKind) -> Bool {
        var query = baseQuery(account: provider.rawValue)
        query[kSecReturnData as String] = false
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    // MARK: - Private

    private func baseQuery(account: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let group = accessGroup {
            q[kSecAttrAccessGroup as String] = group
        }
        return q
    }
}

// MARK: - In-Memory Mock (for tests)

public final class InMemoryKeychainStore: KeychainStoreType, @unchecked Sendable {
    private var store: [String: String] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ value: String, for provider: ProviderKind) throws {
        lock.lock()
        defer { lock.unlock() }
        store[provider.rawValue] = value
    }

    public func read(for provider: ProviderKind) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return store[provider.rawValue]
    }

    public func delete(for provider: ProviderKind) throws {
        lock.lock()
        defer { lock.unlock() }
        store.removeValue(forKey: provider.rawValue)
    }

    public func exists(for provider: ProviderKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return store[provider.rawValue] != nil
    }
}
