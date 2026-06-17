//
//  KimiProviderTests.swift
//  QuotaMonitorTests
//
//  验证 Kimi 平台的鉴权头 + 数据解析
//  v1.0.1 更新：mock JSON 改为 Kimi 真实响应格式（嵌套 limits[0].detail）
//

import XCTest
@testable import QuotaMonitor

final class KimiProviderTests: XCTestCase {
    var client: HTTPClient!

    override func setUp() {
        super.setUp()
        client = MockURLProtocol.makeHTTPClient()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// 真实 Kimi 5h 窗口响应（用于"成功路径"测试）
    private let realKimiJson = """
    {
        "authentication": {"scope": "FEATURE_CODING", "method": "METHOD_API_KEY"},
        "limited": true,
        "limits": [{
            "detail": {
                "limit": "100",
                "used": "40",
                "resetTime": "2026-06-17T20:00:00Z"
            },
            "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"}
        }],
        "totalQuota": {"limit": "100", "remaining": "99"},
        "usage": {"used": "20", "limit": "100", "remaining": "80",
                  "resetTime": "2026-06-24T01:29:19Z"},
        "subType": "TYPE_PURCHASE",
        "parallel": {"limit": "10"}
    }
    """

    // MARK: - 成功路径

    func testSuccessResponse_usedFromDetail() async throws {
        // 关键断言：detail.used 直接是"已用"，不是 limit - remaining
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realKimiJson)
        }

        let quota = try await KimiProvider().fetchQuota(apiKey: "sk-kimi-test", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)

        XCTAssertEqual(quota.provider, .kimi)
        XCTAssertEqual(window.used, 40, accuracy: 0.001,
                       "Kimi: detail.used 直接是已用，不做 limit - remaining")
        XCTAssertEqual(window.total, 100)
        XCTAssertEqual(window.displayName, "5h")
    }

    func testStringNumbersInResponse() async throws {
        // Kimi 字段是字符串（"100" 不是 100），numericValue 必须兼容
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realKimiJson)
        }

        let quota = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.used, 40, accuracy: 0.001,
                       "字符串数字 '40' 必须正确解析为 40")
    }

    func testWindowDurationFrom5Hours() async throws {
        // 验证 displayName 从 window.duration 算出 "5h"
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realKimiJson)
        }

        let quota = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.displayName, "5h",
                       "window.duration=300 分钟 → displayName='5h'")
    }

    // MARK: - 鉴权头验证

    func testBearerAuth_andRequiredUserAgent() async throws {
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realKimiJson)
        }

        _ = try await KimiProvider().fetchQuota(apiKey: "sk-kimi-abc", using: client)

        XCTAssertEqual(MockURLProtocol.capturedRequests.count, 1)
        let req = MockURLProtocol.capturedRequests[0]
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-kimi-abc")
        XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), "KimiCLI/1.30.0",
                       "User-Agent 必须带 KimiCLI 标识才能命中 Coding Plan 专属额度")
    }

    func testEndpoint_isCodingV1Usages() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.path, "/coding/v1/usages",
                          "Kimi 端点必须是 /coding/v1/usages")
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.realKimiJson)
        }

        _ = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
    }

    // MARK: - 错误路径

    func test401_raisesKeyInvalid() async {
        MockURLProtocol.handler = { req in
            MockURLProtocol.errorResponse(url: req.url!, statusCode: 401)
        }

        do {
            _ = try await KimiProvider().fetchQuota(apiKey: "bad", using: client)
            XCTFail("Expected throw")
        } catch let err as QuotaError {
            guard case .keyInvalid(let kind) = err else {
                XCTFail("Expected keyInvalid, got \(err)")
                return
            }
            XCTAssertEqual(kind, .kimi)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test429_raisesRateLimited_withRetryAfter() async {
        MockURLProtocol.handler = { req in
            MockURLProtocol.errorResponse(
                url: req.url!,
                statusCode: 429,
                headers: ["Retry-After": "120"]
            )
        }

        do {
            _ = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
            XCTFail("Expected throw")
        } catch let err as QuotaError {
            guard case .rateLimited(let kind, let retry) = err else {
                XCTFail("Expected rateLimited, got \(err)")
                return
            }
            XCTAssertEqual(kind, .kimi)
            XCTAssertEqual(retry, 120)
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func test500_raisesServerError() async {
        MockURLProtocol.handler = { req in
            MockURLProtocol.errorResponse(url: req.url!, statusCode: 500)
        }

        do {
            _ = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
            XCTFail("Expected throw")
        } catch let err as QuotaError {
            if case .serverError(_, let code, _) = err {
                XCTAssertEqual(code, 500)
                XCTAssertTrue(err.isRetryable, "5xx 错误应可重试")
            } else {
                XCTFail("Expected serverError, got \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testNonJsonResponse_raisesDecodingFailed() async {
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: "not json at all")
        }

        do {
            _ = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
            XCTFail("Expected throw")
        } catch let err as QuotaError {
            guard case .decodingFailed = err else {
                XCTFail("Expected decodingFailed, got \(err)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testMissingLimitsField_raisesDecodingFailed() async {
        // 响应不是预期的 limits 嵌套结构，应抛 decodingFailed
        let badJson = """
        {"authentication": {"scope": "FEATURE_CODING"}}
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: badJson)
        }

        do {
            _ = try await KimiProvider().fetchQuota(apiKey: "k", using: client)
            XCTFail("Expected throw")
        } catch let err as QuotaError {
            guard case .decodingFailed = err else {
                XCTFail("Expected decodingFailed, got \(err)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }
}
