//
//  ProviderQuotaTests.swift
//  QuotaMonitorTests
//
//  验证 ProviderQuota 的窗口指纹（去重状态机的核心）
//

import XCTest
@testable import QuotaMonitor

final class ProviderQuotaTests: XCTestCase {
    func testWindowFingerprint_stableWithin5Hours() {
        // 同一 5h 窗口内，不同时间戳应产生相同 fingerprint
        let t1 = Date(timeIntervalSince1970: 1_716_000_000)  // 2024-05-23 12:00:00 UTC
        let t2 = Date(timeIntervalSince1970: 1_716_000_000 + 60)  // 1 分钟后
        let t3 = Date(timeIntervalSince1970: 1_716_000_000 + 3600)  // 1 小时后

        let q1 = ProviderQuota(provider: .kimi, capturedAt: t1, primaryWindow: nil)
        let q2 = ProviderQuota(provider: .kimi, capturedAt: t2, primaryWindow: nil)
        let q3 = ProviderQuota(provider: .kimi, capturedAt: t3, primaryWindow: nil)

        XCTAssertEqual(q1.windowFingerprint, q2.windowFingerprint,
                       "同一窗口内 fingerprint 应相同")
        XCTAssertEqual(q1.windowFingerprint, q3.windowFingerprint,
                       "1 小时内 fingerprint 应相同")
    }

    func testWindowFingerprint_changesAt5HourBoundary() {
        // 跨过 5h 边界时，fingerprint 应变化
        // 5h = 18000s
        let t1 = Date(timeIntervalSince1970: 1_716_000_000)
        let t2 = Date(timeIntervalSince1970: 1_716_000_000 + 18000)  // 正好 5h 后
        let t3 = Date(timeIntervalSince1970: 1_716_000_000 + 18001)  // 5h+1s

        let q1 = ProviderQuota(provider: .kimi, capturedAt: t1, primaryWindow: nil)
        let q2 = ProviderQuota(provider: .kimi, capturedAt: t2, primaryWindow: nil)
        let q3 = ProviderQuota(provider: .kimi, capturedAt: t3, primaryWindow: nil)

        XCTAssertNotEqual(q1.windowFingerprint, q2.windowFingerprint,
                          "跨过 5h 边界 fingerprint 应变化")
        XCTAssertEqual(q2.windowFingerprint, q3.windowFingerprint,
                       "5h 边界后短时间内 fingerprint 应保持")
    }

    func testWindowFingerprint_distinguishesPlatforms() {
        let t = Date()
        let qKimi = ProviderQuota(provider: .kimi, capturedAt: t, primaryWindow: nil)
        let qMiniMax = ProviderQuota(provider: .minimax, capturedAt: t, primaryWindow: nil)
        let qGLM = ProviderQuota(provider: .glm, capturedAt: t, primaryWindow: nil)

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
