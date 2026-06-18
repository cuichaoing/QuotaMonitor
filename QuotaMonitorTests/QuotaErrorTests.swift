//
//  QuotaErrorTests.swift
//  QuotaMonitorTests
//
//  验证 QuotaError 的 isRetryable / isUserActionable 分类
//

import XCTest
@testable import QuotaMonitor

final class QuotaErrorTests: XCTestCase {
    // MARK: - isRetryable

    func testRateLimited_isRetryable() {
        XCTAssertTrue(QuotaError.rateLimited(.kimi, retryAfter: nil).isRetryable)
        XCTAssertTrue(QuotaError.rateLimited(.kimi, retryAfter: 60).isRetryable)
    }

    func testNetworkUnreachable_isRetryable() {
        XCTAssertTrue(QuotaError.networkUnreachable(.kimi, underlying: nil).isRetryable)
    }

    func testServerError5xx_isRetryable() {
        XCTAssertTrue(QuotaError.serverError(.kimi, statusCode: 500, message: nil).isRetryable)
        XCTAssertTrue(QuotaError.serverError(.kimi, statusCode: 502, message: nil).isRetryable)
        XCTAssertTrue(QuotaError.serverError(.kimi, statusCode: 503, message: nil).isRetryable)
    }

    func testServerError4xx_notRetryable() {
        XCTAssertFalse(QuotaError.serverError(.kimi, statusCode: 400, message: nil).isRetryable)
        XCTAssertFalse(QuotaError.serverError(.kimi, statusCode: 404, message: nil).isRetryable)
    }

    func testKeyInvalid_notRetryable() {
        XCTAssertFalse(QuotaError.keyInvalid(.kimi).isRetryable)
    }

    func testKeyMissing_notRetryable() {
        XCTAssertFalse(QuotaError.keyMissing(.kimi).isRetryable)
    }

    func testCancelled_notRetryable() {
        XCTAssertFalse(QuotaError.cancelled.isRetryable)
    }

    // MARK: - isUserActionable

    func testKeyMissing_isUserActionable() {
        XCTAssertTrue(QuotaError.keyMissing(.kimi).isUserActionable,
                      "未配置 Key 必须引导去设置页")
        XCTAssertTrue(QuotaError.keyMissing(.minimax).isUserActionable)
        XCTAssertTrue(QuotaError.keyMissing(.glm).isUserActionable)
    }

    func testKeyInvalid_isUserActionable() {
        XCTAssertTrue(QuotaError.keyInvalid(.kimi).isUserActionable,
                      "Key 无效必须提示用户重输")
    }

    func testNetworkErrors_notUserActionable() {
        XCTAssertFalse(QuotaError.networkUnreachable(.kimi, underlying: nil).isUserActionable)
        XCTAssertFalse(QuotaError.rateLimited(.kimi, retryAfter: nil).isUserActionable)
    }

    // MARK: - errorDescription

    func testErrorDescription_containsProviderName() {
        let err = QuotaError.keyMissing(.kimi)
        XCTAssertTrue(err.errorDescription?.contains("Kimi") == true)
    }

    // MARK: - networkUnreachable underlying（BUG-2026-06-18-01 A-2）

    func testNetworkUnreachable_errorDescription_includesUnderlying() {
        let err = QuotaError.networkUnreachable(.glm, underlying: "URLError: timedOut")
        XCTAssertEqual(err.errorDescription, "Zhipu GLM 网络不可达（URLError: timedOut）")
    }

    func testNetworkUnreachable_withoutUnderlying_keepsPlainMessage() {
        let err = QuotaError.networkUnreachable(.kimi, underlying: nil)
        XCTAssertEqual(err.errorDescription, "Kimi Code 网络不可达")
    }
}
