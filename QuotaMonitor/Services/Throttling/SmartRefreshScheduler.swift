//
//  SmartRefreshScheduler.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  四级自适应节流：30s / 1m / 5m / 暂停
//  借鉴 Usage4Claude 实现（活动级别变更即响应，无需等待当前 tick）
//

import Foundation
import os

public final class SmartRefreshScheduler: @unchecked Sendable {
    public typealias TickHandler = @Sendable () async -> Void

    public var onTick: TickHandler?

    private let networking: NetworkingService
    private let activityMonitor: SystemActivityMonitor
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Throttle")

    private var currentLevel: ActivityLevel = .normal
    private var streamTask: Task<Void, Never>?
    private var loopTask: Task<Void, Never>?
    private let stateLock = NSLock()
    private var isRunning: Bool = false

    public init(
        networking: NetworkingService = .shared,
        activityMonitor: SystemActivityMonitor = .shared
    ) {
        self.networking = networking
        self.activityMonitor = activityMonitor
    }

    // MARK: - Lifecycle

    public func start() {
        stateLock.lock()
        guard !isRunning else {
            stateLock.unlock()
            return
        }
        isRunning = true
        stateLock.unlock()

        // 1. 订阅活动级别流
        streamTask = Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            for await level in self.activityMonitor.levelStream {
                self.applyLevel(level)
            }
        }

        // 2. 启动 runLoop
        loopTask = Task.detached(priority: .background) { [weak self] in
            await self?.runLoop()
        }

        logger.info("SmartRefreshScheduler started")
    }

    public func stop() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()

        streamTask?.cancel()
        streamTask = nil
        loopTask?.cancel()
        loopTask = nil

        logger.info("SmartRefreshScheduler stopped")
    }

    /// 立即强制触发一次（手动刷新按钮）
    public func forceTick() {
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.onTick?()
        }
    }

    // MARK: - Internal

    private func applyLevel(_ level: ActivityLevel) {
        stateLock.lock()
        let changed = (currentLevel != level)
        currentLevel = level
        stateLock.unlock()

        if changed {
            logger.info("Activity level -> \(level.displayName, privacy: .public) (interval: \(level.refreshIntervalSeconds, privacy: .public)s)")
        }
    }

    private func currentLevelSnapshot() -> ActivityLevel {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentLevel
    }

    private func runLoop() async {
        // 启动时立即跑一次
        await onTick?()

        while !Task.isCancelled {
            let level = currentLevelSnapshot()

            if level.shouldSkipTick {
                // 休眠期：等待唤醒事件即可（唤醒后会从 NSWorkspace.didWakeNotification 收到 .active）
                // 用 60s 长轮询兜底，避免无限阻塞
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                continue
            }

            let interval = level.refreshIntervalSeconds
            logger.debug("next tick in \(interval, privacy: .public)s")

            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return   // cancelled
            }

            // 唤醒时再检查一次 level（避免 sleep 期间被改成 sleeping 仍然跑抓取）
            if currentLevelSnapshot().shouldSkipTick { continue }

            await onTick?()
        }
    }
}
