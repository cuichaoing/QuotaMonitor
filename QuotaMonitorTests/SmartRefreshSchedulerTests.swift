//
//  SmartRefreshSchedulerTests.swift
//  QuotaMonitorTests
//
//  验证节流间隔配置 + ActivityLevel 状态机
//

import XCTest
@testable import QuotaMonitor

final class SmartRefreshSchedulerTests: XCTestCase {
    // MARK: - 节流间隔

    func testActivityLevelIntervals_matchesDesign() {
        XCTAssertEqual(ActivityLevel.active.refreshIntervalSeconds, 30)
        XCTAssertEqual(ActivityLevel.normal.refreshIntervalSeconds, 60)
        XCTAssertEqual(ActivityLevel.idle.refreshIntervalSeconds, 300)
    }

    func testActivityLevelIntervals_areReasonable() {
        for level in ActivityLevel.allCases {
            XCTAssertGreaterThan(level.refreshIntervalSeconds, 0,
                                 "\(level) 间隔必须 > 0")
            XCTAssertLessThanOrEqual(level.refreshIntervalSeconds, 3600,
                                     "\(level) 间隔不应超过 1h")
        }
    }

    // MARK: - 跳过逻辑

    func testShouldSkipTick_onlySleeping() {
        XCTAssertTrue(ActivityLevel.sleeping.shouldSkipTick,
                      "休眠期必须跳过抓取以省电")
        XCTAssertFalse(ActivityLevel.active.shouldSkipTick)
        XCTAssertFalse(ActivityLevel.normal.shouldSkipTick)
        XCTAssertFalse(ActivityLevel.idle.shouldSkipTick)
    }

    // MARK: - 状态机顺序

    func testOrderComparable() {
        XCTAssertLessThan(ActivityLevel.active, ActivityLevel.normal)
        XCTAssertLessThan(ActivityLevel.normal, ActivityLevel.idle)
        XCTAssertLessThan(ActivityLevel.idle, ActivityLevel.sleeping)
    }

    func testAllCasesCount() {
        XCTAssertEqual(ActivityLevel.allCases.count, 4)
    }

    // MARK: - 集成测试：forceTick 触发回调

    func testForceTick_invokesOnTick() async throws {
        let monitor = SystemActivityMonitor.shared
        let service = NetworkingService.shared
        let scheduler = SmartRefreshScheduler(networking: service, activityMonitor: monitor)

        let counter = TickCounter()
        scheduler.onTick = { [counter] in
            await counter.increment()
        }

        scheduler.forceTick()

        // 等待 200ms 让异步任务跑
        try await Task.sleep(nanoseconds: 200_000_000)

        let count = await counter.value
        XCTAssertGreaterThanOrEqual(count, 1, "forceTick 应至少触发一次 onTick")
    }
}

/// 线程安全的计数器（用于 async test 中统计闭包调用次数）
actor TickCounter {
    private(set) var value: Int = 0

    func increment() {
        value += 1
    }
}
