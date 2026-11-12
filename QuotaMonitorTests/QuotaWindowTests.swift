//
//  QuotaWindowTests.swift
//  QuotaMonitorTests
//
//  验证 QuotaWindow 计算逻辑
//

import XCTest
@testable import QuotaMonitor

final class QuotaWindowTests: XCTestCase {
    func testUsedPercent_basic() {
        let w = QuotaWindow(total: 100, used: 30, resetAt: Date(), displayName: "5h")
        XCTAssertEqual(w.usedPercent, 30, accuracy: 0.001)
        XCTAssertEqual(w.remainingPercent, 70, accuracy: 0.001)
        XCTAssertEqual(w.remaining, 70, accuracy: 0.001)
    }

    func testUsedPercent_cappedAt100() {
        let w = QuotaWindow(total: 100, used: 150, resetAt: Date(), displayName: "5h")
        XCTAssertEqual(w.usedPercent, 100, accuracy: 0.001)
    }

    func testUsedPercent_zeroTotal_returnsZero() {
        let w = QuotaWindow(total: 0, used: 0, resetAt: Date(), displayName: "5h")
        XCTAssertEqual(w.usedPercent, 0, "total=0 时不能除零")
    }

    func testRemaining_neverNegative() {
        let w = QuotaWindow(total: 100, used: 150, resetAt: Date(), displayName: "5h")
        XCTAssertEqual(w.remaining, 0, accuracy: 0.001, "used > total 时 remaining 不可为负")
    }

    func testUsedPercent_GLMDirectPercent() {
        // GLM 端点直接返回百分比，total=100, used=percent
        let w = QuotaWindow(total: 100, used: 75, resetAt: Date(), displayName: "5h")
        XCTAssertEqual(w.usedPercent, 75, accuracy: 0.001)
    }

    func testEquatable() {
        let now = Date()
        let a = QuotaWindow(total: 100, used: 30, resetAt: now, displayName: "5h")
        let b = QuotaWindow(total: 100, used: 30, resetAt: now, displayName: "5h")
        let c = QuotaWindow(total: 100, used: 40, resetAt: now, displayName: "5h")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testExpectedPercentByElapsedPeriod_weekly() {
        let sevenDays: TimeInterval = 7 * 24 * 3600
        let resetAt = Date(timeIntervalSince1970: 1_800_000_000)
        let w = QuotaWindow(total: 100, used: 0, resetAt: resetAt, displayName: "7d")

        // 周期起点 = 0%
        let periodStart = resetAt.addingTimeInterval(-sevenDays)
        XCTAssertEqual(w.expectedPercentByElapsedPeriod(periodSeconds: sevenDays, now: periodStart), 0, accuracy: 0.01)
        // 周期中点（3.5 天）= 50%
        let midpoint = resetAt.addingTimeInterval(-sevenDays / 2)
        XCTAssertEqual(w.expectedPercentByElapsedPeriod(periodSeconds: sevenDays, now: midpoint), 50, accuracy: 0.01)
        // 周期终点 = 100%
        XCTAssertEqual(w.expectedPercentByElapsedPeriod(periodSeconds: sevenDays, now: resetAt), 100, accuracy: 0.01)
        // 越界：晚于 resetAt clamp 到 100%
        XCTAssertEqual(w.expectedPercentByElapsedPeriod(periodSeconds: sevenDays, now: resetAt.addingTimeInterval(1000)), 100, accuracy: 0.01)
        // 越界：早于周期起点 clamp 到 0%
        XCTAssertEqual(w.expectedPercentByElapsedPeriod(periodSeconds: sevenDays, now: periodStart.addingTimeInterval(-1000)), 0, accuracy: 0.01)
    }
}
