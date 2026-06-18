//
//  MenuBarControllerTests.swift
//  QuotaMonitorTests
//
//  验证状态栏显示决策（MenuBarSegment.resolve）。
//  BUG-2026-06-18-01 根因 B：状态栏此前只读 snapshots、忽略 errors，
//  导致某平台失败时状态栏仍显示旧百分比或 "--"，与 Popup 的 "离线" 红标不一致。
//

import XCTest
@testable import QuotaMonitor

final class MenuBarControllerTests: XCTestCase {

    // MARK: - 显示决策优先级

    func testResolve_error_showsFailed() {
        // 有 error（本轮抓取失败）→ 显示失败标记，不显示旧百分比
        let snap = makeQuota(used: 33)
        let seg = MenuBarSegment.resolve(snapshot: snap, error: .networkUnreachable(.glm))
        XCTAssertEqual(seg, .failed, "有 error 时应显示失败标记，而非旧百分比 33")
    }

    func testResolve_success_showsValue() {
        let snap = makeQuota(used: 33)
        let seg = MenuBarSegment.resolve(snapshot: snap, error: nil)
        XCTAssertEqual(seg, .value(displayPercent: 33, rawPercent: 33))
    }

    func testResolve_noData_showsPlaceholder() {
        let seg = MenuBarSegment.resolve(snapshot: nil, error: nil)
        XCTAssertEqual(seg, .placeholder)
    }

    /// 关键：error 必须优先于 snapshot。
    /// 这是状态栏与 Popup 不一致的根因：旧 snapshot 残留 + 状态栏只看 snapshot。
    func testResolve_errorTakesPrecedenceOverSnapshot() {
        let snap = makeQuota(used: 80)
        let seg = MenuBarSegment.resolve(snapshot: snap, error: .networkUnreachable(.minimax))
        XCTAssertEqual(seg, .failed,
                       "error 必须优先于旧 snapshot，否则状态栏会显示陈旧的 80% 而 Popup 显示离线")
    }

    // MARK: - 取整一致性（复用 v1.0.6 displayPercent 四舍五入规则）

    func testResolve_usesRoundedDisplayPercent() {
        // raw=33.6 → displayPercent 四舍五入 34
        let snap = makeQuota(used: 33.6)
        let seg = MenuBarSegment.resolve(snapshot: snap, error: nil)
        XCTAssertEqual(seg, .value(displayPercent: 34, rawPercent: 33.6))
    }

    // MARK: - Helper

    private func makeQuota(used: Double) -> ProviderQuota {
        ProviderQuota(
            provider: .glm,
            primaryWindow: QuotaWindow(total: 100, used: used, resetAt: Date(), displayName: "5h")
        )
    }
}
