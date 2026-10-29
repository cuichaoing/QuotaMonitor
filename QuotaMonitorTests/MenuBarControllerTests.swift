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

    // MARK: - 标题渲染方案（v1.1.1）

    /// 全绿 → 安静模式：只显示数字，不带字母
    func testPlan_allGreen_isQuiet() {
        let plan = MenuBarTitlePlan(
            snapshots: [
                .kimi: makeQuota(used: 20, kind: .kimi),
                .minimax: makeQuota(used: 30, kind: .minimax),
                .gemini: makeQuota(used: 10, kind: .gemini),
                .glm: makeQuota(used: 5, kind: .glm),
            ],
            errors: [:], warningThreshold: 75, dangerThreshold: 99)
        XCTAssertTrue(plan.quiet, "全部绿色时应进入安静模式")
        XCTAssertEqual(plan.items.count, 4)
    }

    /// 有平台越过警告阈值 → 字母回归
    func testPlan_oneYellow_notQuiet() {
        let plan = MenuBarTitlePlan(
            snapshots: [
                .kimi: makeQuota(used: 20, kind: .kimi),
                .minimax: makeQuota(used: 80, kind: .minimax),
            ],
            errors: [:], warningThreshold: 75, dangerThreshold: 99)
        XCTAssertFalse(plan.quiet)
    }

    /// 有平台抓取失败 → 字母回归（且显示 !）
    func testPlan_hasError_notQuiet() {
        let plan = MenuBarTitlePlan(
            snapshots: [.kimi: makeQuota(used: 10, kind: .kimi)],
            errors: [.glm: .networkUnreachable(.glm)],
            warningThreshold: 75, dangerThreshold: 99)
        XCTAssertFalse(plan.quiet)
        XCTAssertTrue(plan.items.contains { if case .failed = $0 { return true } else { return false } })
    }

    /// 未配置平台（占位）→ 字母回归
    func testPlan_placeholder_notQuiet() {
        let plan = MenuBarTitlePlan(
            snapshots: [.kimi: makeQuota(used: 10, kind: .kimi)],
            errors: [:], warningThreshold: 75, dangerThreshold: 99)
        XCTAssertFalse(plan.quiet, "存在未配置平台时不算全绿")
    }

    /// 打满 100% → isExhausted = true（渲染时附括号倒计时）
    func testPlan_exhaustedFlag() {
        let plan = MenuBarTitlePlan(
            snapshots: [
                .kimi: makeQuota(used: 100, kind: .kimi),
                .glm: makeQuota(used: 10, kind: .glm),
            ],
            errors: [:], warningThreshold: 75, dangerThreshold: 99)
        var exhausted: Int?
        for item in plan.items {
            if case .value(let kind, let display, _, let isExhausted) = item, kind == .kimi {
                exhausted = isExhausted ? display : nil
            }
        }
        XCTAssertEqual(exhausted, 100)
        XCTAssertFalse(plan.quiet)
    }

    /// 倒计时文案格式
    func testCompactDuration() {
        XCTAssertEqual(MenuBarTitlePlan.compactDuration(3600 * 2 + 60 * 56), "2h56m")
        XCTAssertEqual(MenuBarTitlePlan.compactDuration(3600 * 2), "2h")
        XCTAssertEqual(MenuBarTitlePlan.compactDuration(60 * 45), "45m")
        XCTAssertEqual(MenuBarTitlePlan.compactDuration(12), "12s")
        XCTAssertEqual(MenuBarTitlePlan.compactDuration(-5), "0s")
    }

    // MARK: - Helper

    private func makeQuota(used: Double, kind: ProviderKind = .glm) -> ProviderQuota {
        ProviderQuota(
            provider: kind,
            primaryWindow: QuotaWindow(total: 100, used: used, resetAt: Date(), displayName: "5h")
        )
    }
}
