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
}
