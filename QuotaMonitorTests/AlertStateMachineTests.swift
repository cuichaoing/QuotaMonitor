//
//  AlertStateMachineTests.swift
//  QuotaMonitorTests
//
//  告警状态机测试：3 级阈值 + 5h 窗口指纹去重
//

import XCTest
@testable import QuotaMonitor

final class AlertStateMachineTests: XCTestCase {
    var machine: AlertStateMachine!

    override func setUp() {
        super.setUp()
        machine = AlertStateMachine()
    }

    // MARK: - 阈值分级

    func testClassify_belowWarning_isNone() {
        XCTAssertEqual(
            AlertLevel.classify(usedPercent: 50, warning: 75, critical: 90, danger: 99),
            .none
        )
    }

    func testClassify_atWarning_isWarning() {
        XCTAssertEqual(
            AlertLevel.classify(usedPercent: 75, warning: 75, critical: 90, danger: 99),
            .warning
        )
    }

    func testClassify_betweenWarningAndCritical_isWarning() {
        XCTAssertEqual(
            AlertLevel.classify(usedPercent: 80, warning: 75, critical: 90, danger: 99),
            .warning
        )
    }

    func testClassify_atCritical_isCritical() {
        XCTAssertEqual(
            AlertLevel.classify(usedPercent: 90, warning: 75, critical: 90, danger: 99),
            .critical
        )
    }

    func testClassify_atDanger_isDanger() {
        XCTAssertEqual(
            AlertLevel.classify(usedPercent: 99, warning: 75, critical: 90, danger: 99),
            .danger
        )
    }

    func testClassify_aboveDanger_isDanger() {
        XCTAssertEqual(
            AlertLevel.classify(usedPercent: 100, warning: 75, critical: 90, danger: 99),
            .danger
        )
    }

    // MARK: - 5h 窗口去重

    func testEvaluate_sameWindowSameLevel_emitsOnce() {
        let quota = makeQuota(usedPercent: 80)  // warning
        let snapshot: [ProviderKind: ProviderQuota] = [.kimi: quota]

        let events1 = machine.evaluate(snapshots: snapshot, thresholds: (75, 90, 99))
        let events2 = machine.evaluate(snapshots: snapshot, thresholds: (75, 90, 99))

        XCTAssertEqual(events1.count, 1)
        XCTAssertEqual(events2.count, 0, "同窗口同等级不重复发")
    }

    func testEvaluate_newWindow_resetsDedup() {
        // 第一次：窗口 A 内 warning
        let quotaA = makeQuota(usedPercent: 80, capturedAt: Date(timeIntervalSince1970: 1_000_000))
        let events1 = machine.evaluate(snapshots: [.kimi: quotaA], thresholds: (75, 90, 99))
        XCTAssertEqual(events1.count, 1)

        // 第二次：窗口 B（capturedAt 间隔 5h+，新 fingerprint）
        let quotaB = makeQuota(usedPercent: 80, capturedAt: Date(timeIntervalSince1970: 1_000_000 + 18_001))
        let events2 = machine.evaluate(snapshots: [.kimi: quotaB], thresholds: (75, 90, 99))
        XCTAssertEqual(events2.count, 1, "跨窗口应重置去重")
    }

    // MARK: - 等级升级

    func testEvaluate_warningToCritical_emitsAgain() {
        // 第一次 warning
        let quota1 = makeQuota(usedPercent: 80, fingerprint: "kimi-window-X")
        let events1 = machine.evaluate(snapshots: [.kimi: quota1], thresholds: (75, 90, 99))
        XCTAssertEqual(events1.count, 1)
        XCTAssertEqual(events1.first?.level, .warning)

        // 第二次 critical（升级）
        let quota2 = makeQuota(usedPercent: 92, fingerprint: "kimi-window-X")
        let events2 = machine.evaluate(snapshots: [.kimi: quota2], thresholds: (75, 90, 99))
        XCTAssertEqual(events2.count, 1, "等级升级应视为新事件")
        XCTAssertEqual(events2.first?.level, .critical)
    }

    func testEvaluate_criticalToWarning_doesNotEmit() {
        // 第一次 critical
        let quota1 = makeQuota(usedPercent: 92, fingerprint: "kimi-window-Y")
        let events1 = machine.evaluate(snapshots: [.kimi: quota1], thresholds: (75, 90, 99))
        XCTAssertEqual(events1.first?.level, .critical)

        // 第二次 warning（降级，不应再发）
        let quota2 = makeQuota(usedPercent: 80, fingerprint: "kimi-window-Y")
        let events2 = machine.evaluate(snapshots: [.kimi: quota2], thresholds: (75, 90, 99))
        XCTAssertEqual(events2.count, 0, "降级不重复发")
    }

    // MARK: - 多平台

    func testEvaluate_multiplePlatforms_independentDedup() {
        let kimiWarning = makeQuota(usedPercent: 80, fingerprint: "kimi-A")
        let glmWarning = makeQuota(usedPercent: 80, fingerprint: "glm-A", provider: .glm)

        let events = machine.evaluate(
            snapshots: [.kimi: kimiWarning, .glm: glmWarning],
            thresholds: (75, 90, 99)
        )

        XCTAssertEqual(events.count, 2, "两个平台应各自独立发告警")
        XCTAssertTrue(events.contains { $0.provider == .kimi })
        XCTAssertTrue(events.contains { $0.provider == .glm })
    }

    // MARK: - Reset

    func testReset_clearsDedupState() {
        let quota = makeQuota(usedPercent: 80)
        let snapshot: [ProviderKind: ProviderQuota] = [.kimi: quota]

        _ = machine.evaluate(snapshots: snapshot, thresholds: (75, 90, 99))
        machine.reset()
        let events = machine.evaluate(snapshots: snapshot, thresholds: (75, 90, 99))
        XCTAssertEqual(events.count, 1, "reset 后应重新发")
    }

    // MARK: - Helper

    private func makeQuota(
        usedPercent: Double,
        fingerprint: String = "kimi-default",
        provider: ProviderKind = .kimi,
        capturedAt: Date = Date()
    ) -> ProviderQuota {
        let window = QuotaWindow(
            total: 100,
            used: usedPercent,
            resetAt: capturedAt.addingTimeInterval(18000),
            displayName: "5h"
        )
        return ProviderQuota(
            provider: provider,
            capturedAt: capturedAt,
            primaryWindow: window
        )
    }
}
