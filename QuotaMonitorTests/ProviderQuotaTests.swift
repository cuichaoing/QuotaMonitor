//
//  ProviderQuotaTests.swift
//  QuotaMonitorTests
//
//  验证 ProviderQuota 的窗口指纹（去重状态机的核心）
//

import XCTest
@testable import QuotaMonitor

final class ProviderQuotaTests: XCTestCase {
    // MARK: - 窗口指纹（v1.0.9：锚定服务端 resetAt，而非抓取时刻）
    // 修复 BUG-2026-06-19-01：原指纹按 capturedAt/18000 机械切桶，与服务端真实窗口
    // 相位错位，导致真实窗口重置后被 applySmoothing 误判为「同窗口倒退」而卡住旧值。
    // 新语义：同一 resetAt = 同一窗口（防抖/告警去重生效）；resetAt 变 = 新窗口（接受真实新值）。

    func testWindowFingerprint_stableForSameResetAt() {
        // 同一服务端窗口（resetAt 相同）内，不同抓取时刻应产生相同 fingerprint
        let reset = Date(timeIntervalSince1970: 1_750_300_000)
        let win = QuotaWindow(total: 100, used: 3, resetAt: reset, displayName: "5h")

        let q1 = ProviderQuota(provider: .glm, capturedAt: Date(timeIntervalSince1970: 1_750_300_060), primaryWindow: win)
        let q2 = ProviderQuota(provider: .glm, capturedAt: Date(timeIntervalSince1970: 1_750_303_600), primaryWindow: win)

        XCTAssertEqual(q1.windowFingerprint, q2.windowFingerprint,
                       "同一 resetAt（同一窗口）内 fingerprint 应相同")
    }

    func testWindowFingerprint_changesWhenServerWindowResets() {
        // 服务端窗口重置（resetAt 变化）时，fingerprint 必须变化
        // —— 否则平滑逻辑会把新窗口的真实低值误判为「同窗口倒退」而丢弃（BUG-2026-06-19-01）。
        // 注意：两次 capturedAt 故意落在同一 18000s 桶内（模拟 05:27 vs 05:28 同桶），
        // 旧实现（按 capturedAt 切桶）下两者指纹相同 → 本断言失败（RED）。
        let oldReset = Date(timeIntervalSince1970: 1_750_300_000)
        let newReset = Date(timeIntervalSince1970: 1_750_318_000)  // +5h，新窗口重置点

        let qOld = ProviderQuota(provider: .glm,
                                 capturedAt: Date(timeIntervalSince1970: 1_750_300_060),
                                 primaryWindow: QuotaWindow(total: 100, used: 13, resetAt: oldReset, displayName: "5h"))
        let qNew = ProviderQuota(provider: .glm,
                                 capturedAt: Date(timeIntervalSince1970: 1_750_300_120),
                                 primaryWindow: QuotaWindow(total: 100, used: 3, resetAt: newReset, displayName: "5h"))

        XCTAssertNotEqual(qOld.windowFingerprint, qNew.windowFingerprint,
                          "服务端窗口重置（resetAt 变）后 fingerprint 必须变化")
    }

    func testWindowFingerprint_distinguishesPlatforms() {
        let reset = Date(timeIntervalSince1970: 1_750_300_000)
        let win = QuotaWindow(total: 100, used: 5, resetAt: reset, displayName: "5h")
        let qKimi = ProviderQuota(provider: .kimi, primaryWindow: win)
        let qMiniMax = ProviderQuota(provider: .minimax, primaryWindow: win)
        let qGLM = ProviderQuota(provider: .glm, primaryWindow: win)

        XCTAssertNotEqual(qKimi.windowFingerprint, qMiniMax.windowFingerprint)
        XCTAssertNotEqual(qKimi.windowFingerprint, qGLM.windowFingerprint)
        XCTAssertNotEqual(qMiniMax.windowFingerprint, qGLM.windowFingerprint)
    }

    // MARK: - displayPercent（v1.0.6：统一状态栏与 popup 的取整，杜绝显示分裂）

    func testDisplayPercent_roundsHalfAwayFromZero() {
        // 四舍五入边界（.5 向上，away from zero）。
        // 这正是状态栏 Int()（截断）与 popup %.0f 行为不一致的高发区：
        //   例如 used=1.6 截断得 1、四舍五入得 2；used=2.5 截断得 2、四舍五入得 3。
        // displayPercent 作为状态栏与 popup 共用的显示值，必须用同一套四舍五入规则。
        let cases: [(used: Double, expected: Int)] = [
            (0.4, 0),
            (0.5, 1),
            (1.4, 1),
            (1.6, 2),
            (2.5, 3),
            (59.6, 60),   // 阈值边界：59.6 应显示 60
        ]
        for c in cases {
            let q = ProviderQuota(
                provider: .minimax,
                primaryWindow: QuotaWindow(total: 100, used: c.used, resetAt: Date(), displayName: "5h")
            )
            XCTAssertEqual(q.displayPercent, c.expected,
                          "used=\(c.used) 应四舍五入为 \(c.expected)")
        }
    }

    func testDisplayPercent_nilWhenNoWindow() {
        let q = ProviderQuota(provider: .minimax, capturedAt: Date(), primaryWindow: nil)
        XCTAssertNil(q.displayPercent, "无窗口时 displayPercent 应为 nil")
    }
}
