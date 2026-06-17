//
//  ProviderKindTests.swift
//  QuotaMonitorTests
//
//  验证 ProviderKind 枚举字段的稳定性
//

import XCTest
@testable import QuotaMonitor

final class ProviderKindTests: XCTestCase {
    func testAllCases_count() {
        XCTAssertEqual(ProviderKind.allCases.count, 3)
    }

    func testSortOrder_unique() {
        let orders = ProviderKind.allCases.map { $0.sortOrder }
        XCTAssertEqual(Set(orders).count, 3, "sortOrder 必须唯一")
    }

    func testDisplayNames_unique() {
        let names = ProviderKind.allCases.map { $0.displayName }
        XCTAssertEqual(Set(names).count, 3, "displayName 必须唯一")
    }

    func testUserAgent_OnlyKimiRequired() {
        XCTAssertNotNil(ProviderKind.kimi.requiredUserAgent,
                        "Kimi 必须带 User-Agent 才能命中 Coding Plan 专属额度")
        XCTAssertNil(ProviderKind.minimax.requiredUserAgent)
        XCTAssertNil(ProviderKind.glm.requiredUserAgent)
    }

    func testBearerPrefix_GLMForbidden() {
        // 关键防坑：GLM Authorization 不能带 "Bearer " 前缀
        XCTAssertTrue(ProviderKind.kimi.requiresBearerPrefix)
        XCTAssertTrue(ProviderKind.minimax.requiresBearerPrefix)
        XCTAssertFalse(ProviderKind.glm.requiresBearerPrefix,
                       "GLM 必须用裸 Token，加 Bearer 会 401")
    }

    func testBaseURLs_allValid() {
        for kind in ProviderKind.allCases {
            XCTAssertNotNil(kind.defaultBaseURL.host, "\(kind) base URL 解析失败")
            XCTAssertTrue(kind.defaultBaseURL.scheme?.hasPrefix("https") == true,
                          "\(kind) 必须使用 HTTPS")
        }
    }

    func testKimiUserAgent_format() {
        let ua = ProviderKind.kimi.requiredUserAgent
        XCTAssertTrue(ua?.contains("KimiCLI") == true, "User-Agent 应含 KimiCLI 标识")
    }
}
