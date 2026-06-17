//
//  QuotaStore.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  当前配额快照存储（@Published 触发 UI 刷新）
//

import Foundation
import Combine

@MainActor
public final class QuotaStore: ObservableObject {
    public static let shared = QuotaStore()

    @Published public private(set) var snapshots: [ProviderKind: ProviderQuota] = [:]
    @Published public private(set) var errors: [ProviderKind: QuotaError] = [:]
    @Published public private(set) var lastRefreshAt: Date?
    @Published public private(set) var isRefreshing: Bool = false

    public init() {}

    public func update(snapshots: [ProviderKind: ProviderQuota], errors: [ProviderKind: QuotaError]) {
        self.snapshots = snapshots
        self.errors = errors
        self.lastRefreshAt = Date()
    }

    public func setRefreshing(_ value: Bool) {
        self.isRefreshing = value
    }

    public func clear() {
        snapshots.removeAll()
        errors.removeAll()
        lastRefreshAt = nil
    }

    // MARK: - 派生

    /// 没有任何快照（首次启动 / 全部平台未配置 Key）
    public var hasAnySnapshot: Bool {
        !snapshots.isEmpty
    }
}
