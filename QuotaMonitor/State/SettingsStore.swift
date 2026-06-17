//
//  SettingsStore.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  用户配置状态：
//   - API Key 走 Keychain（KeychainStoreType 协议）
//   - 启用平台 / 阈值 / 刷新频率走 UserDefaults（@AppStorage）
//   - 单一可信源：所有读写都过这个类，避免散落各处的 UserDefaults.standard
//

import Foundation
import Combine
import os

@MainActor
public final class SettingsStore: ObservableObject {
    public static let shared = SettingsStore()

    private let keychain: KeychainStoreType
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Settings")

    // MARK: - Published 配置

    /// 启用的平台（影响 fetchAll 的 kinds 参数）
    @Published public var enabledProviders: Set<ProviderKind> {
        didSet {
            defaults.set(enabledProviders.map(\.rawValue), forKey: Keys.enabledProviders)
            logger.info("enabled providers: \(self.enabledProviders.map(\.rawValue), privacy: .public)")
        }
    }

    /// 是否启用 Bark 推送
    @Published public var barkEnabled: Bool {
        didSet { defaults.set(barkEnabled, forKey: Keys.barkEnabled) }
    }

    /// Bark 服务器 URL（默认官方）
    @Published public var barkServer: String {
        didSet { defaults.set(barkServer, forKey: Keys.barkServer) }
    }

    /// 黄色阈值（默认 75）
    @Published public var warningThreshold: Double {
        didSet { defaults.set(warningThreshold, forKey: Keys.warningThreshold) }
    }

    /// 橙色阈值（默认 90）
    @Published public var criticalThreshold: Double {
        didSet { defaults.set(criticalThreshold, forKey: Keys.criticalThreshold) }
    }

    /// 红色阈值（默认 99）
    @Published public var dangerThreshold: Double {
        didSet { defaults.set(dangerThreshold, forKey: Keys.dangerThreshold) }
    }

    /// 刷新频率覆盖（nil = 用 ActivityLevel 默认值）
    @Published public var activeInterval: Double {
        didSet { defaults.set(activeInterval, forKey: Keys.activeInterval) }
    }
    @Published public var normalInterval: Double {
        didSet { defaults.set(normalInterval, forKey: Keys.normalInterval) }
    }
    @Published public var idleInterval: Double {
        didSet { defaults.set(idleInterval, forKey: Keys.idleInterval) }
    }

    // MARK: - Init

    public init(
        keychain: KeychainStoreType = KeychainStore.shared,
        defaults: UserDefaults = .standard
    ) {
        self.keychain = keychain
        self.defaults = defaults

        // 首次启动：默认启用所有平台
        let storedProviders = defaults.stringArray(forKey: Keys.enabledProviders)?
            .compactMap(ProviderKind.init(rawValue:))
            ?? []
        self.enabledProviders = storedProviders.isEmpty
            ? Set(ProviderKind.allCases)
            : Set(storedProviders)

        self.warningThreshold = defaults.object(forKey: Keys.warningThreshold) as? Double ?? 75
        self.criticalThreshold = defaults.object(forKey: Keys.criticalThreshold) as? Double ?? 90
        self.dangerThreshold = defaults.object(forKey: Keys.dangerThreshold) as? Double ?? 99

        self.activeInterval = defaults.object(forKey: Keys.activeInterval) as? Double ?? 30
        self.normalInterval = defaults.object(forKey: Keys.normalInterval) as? Double ?? 60
        self.idleInterval = defaults.object(forKey: Keys.idleInterval) as? Double ?? 300

        self.barkEnabled = defaults.bool(forKey: Keys.barkEnabled)
        self.barkServer = defaults.string(forKey: Keys.barkServer) ?? "https://api.day.app"
    }

    // MARK: - API Key 操作（走 Keychain）

    public enum KeyState {
        case notConfigured
        case configured
    }

    /// 查询某平台是否已配置 Key
    public func keyState(for kind: ProviderKind) -> KeyState {
        keychain.exists(for: kind) ? .configured : .notConfigured
    }

    /// 保存 API Key（明文只在内存中，不进日志）
    public func saveKey(_ key: String, for kind: ProviderKind) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QuotaError.keyMissing(kind)
        }
        try keychain.save(trimmed, for: kind)
        logger.info("[\(kind.rawValue, privacy: .public)] API key saved")
    }

    /// 删除 API Key
    public func deleteKey(for kind: ProviderKind) throws {
        try keychain.delete(for: kind)
        logger.info("[\(kind.rawValue, privacy: .public)] API key deleted")
    }

    /// 读取已保存的 API Key（明文）。
    /// 调用方应在调用前完成身份验证（如 LAContext）。
    /// 返回 nil 表示该平台未配置 Key。
    public func readKey(for kind: ProviderKind) throws -> String? {
        return try keychain.read(for: kind)
    }

    // MARK: - Bark 操作

    public enum BarkKeyState {
        case notConfigured
        case configured
    }

    /// Bark device key（公开 token，存 UserDefaults 即可）
    public var barkDeviceKey: String {
        defaults.string(forKey: Keys.barkDeviceKey) ?? ""
    }

    public func barkKeyState() -> BarkKeyState {
        barkDeviceKey.isEmpty ? .notConfigured : .configured
    }

    public func saveBarkKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw QuotaError.keyMissing(.kimi)   // 复用 .keyMissing 错误
        }
        defaults.set(trimmed, forKey: Keys.barkDeviceKey)
        logger.info("Bark device key saved")
    }

    public func deleteBarkKey() {
        defaults.removeObject(forKey: Keys.barkDeviceKey)
        logger.info("Bark device key deleted")
    }

    /// 取 Bark 配置（如未配置则返回 nil）
    public func barkConfig() -> BarkConfig? {
        guard barkEnabled else { return nil }
        let key = barkDeviceKey
        guard !key.isEmpty else { return nil }
        let server = URL(string: barkServer) ?? URL(string: "https://api.day.app")!
        return BarkConfig(server: server, deviceKey: key)
    }

    // MARK: - 派生：取当前应抓的 platforms

    /// 返回 fetchAll 需要的 kinds
    public func enabledKinds() -> [ProviderKind] {
        ProviderKind.allCases
            .filter { enabledProviders.contains($0) }
            .sorted { $0.sortOrder < $1.sortOrder }
    }

    /// 某平台是否启用且已配置 Key
    public func shouldFetch(_ kind: ProviderKind) -> Bool {
        enabledProviders.contains(kind) && keyState(for: kind) == .configured
    }

    /// 取某级别的刷新间隔（如果用户没改就返回 nil，让 Scheduler 用默认）
    public func intervalOverride(for level: ActivityLevel) -> TimeInterval? {
        switch level {
        case .active:   return activeInterval
        case .normal:   return normalInterval
        case .idle:     return idleInterval
        case .sleeping: return nil   // 休眠期不调度
        }
    }

    // MARK: - Keys

    private enum Keys {
        static let enabledProviders = "qm.enabledProviders"
        static let warningThreshold = "qm.warningThreshold"
        static let criticalThreshold = "qm.criticalThreshold"
        static let dangerThreshold = "qm.dangerThreshold"
        static let activeInterval = "qm.activeInterval"
        static let normalInterval = "qm.normalInterval"
        static let idleInterval = "qm.idleInterval"
        static let barkEnabled = "qm.barkEnabled"
        static let barkServer = "qm.barkServer"
        static let barkDeviceKey = "qm.barkDeviceKey"
    }
}
