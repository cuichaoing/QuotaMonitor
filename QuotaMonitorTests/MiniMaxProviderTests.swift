//
//  MiniMaxProviderTests.swift
//  QuotaMonitorTests
//
//  验证 MiniMax 的字段语义 + 多 model 选择
//  v1.0.1 更新：响应结构改为 model_remains 数组，
//  usedPercent 由 current_interval_remaining_percent 反算
//

import XCTest
@testable import QuotaMonitor

final class MiniMaxProviderTests: XCTestCase {
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

    /// 真实 MiniMax 响应（用于"成功路径"测试，模拟 45% 已用）
    private let realMiniMaxJson = """
    {
        "model_remains": [
            {
                "model_name": "general",
                "current_interval_usage_count": 0,
                "current_interval_total_count": 0,
                "current_interval_remaining_percent": 55,
                "current_interval_status": 1
            },
            {
                "model_name": "video",
                "current_interval_usage_count": 0,
                "current_interval_total_count": 0,
                "current_interval_remaining_percent": 100,
                "current_interval_status": 3
            }
        ],
        "base_resp": {"status_msg": "success", "status_code": 0}
    }
    """

    // MARK: - 反直觉字段（v1.0.1 修正）

    func testUsedPercent_fromRemainingPercent() async throws {
        // 【关键 v1.0.1】
        // current_interval_remaining_percent = 55 → usedPercent = 100 - 55 = 45
        // （旧 v0.1 测试用 current_interval_usage_count 反算法，已被真实字段推翻）
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realMiniMaxJson)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.used, 45, accuracy: 0.001,
                       "remaining_percent=55 -> used=45 (general model)")
        XCTAssertEqual(window.usedPercent, 45, accuracy: 0.001)
        XCTAssertEqual(window.remaining, 55, accuracy: 0.001)
    }

    func testPrefersGeneralModel_overVideo() async throws {
        // 多 model 场景：优先选 "general" 而不是 "video"（或其他）
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realMiniMaxJson)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        // general 模型 remaining=55 → used=45
        // video 模型 remaining=100 → used=0
        // 应选 general
        XCTAssertEqual(window.used, 45, accuracy: 0.001,
                       "应选 'general' model，不用 'video'（video 是 0% 已用）")
    }

    func testSingleModelResponse() async throws {
        // 只有一个 model 的响应（API 可能简化）
        let json = """
        {
            "model_remains": [{
                "model_name": "general",
                "current_interval_remaining_percent": 30,
                "current_interval_usage_count": 70
            }]
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.used, 70, accuracy: 0.001,
                       "remaining=30 -> used=70")
    }

    func testRemainingHundred_meansZeroUsed() async throws {
        // remaining=100 → used=0 (没开始用)
        let json = """
        {
            "model_remains": [{
                "model_name": "general",
                "current_interval_remaining_percent": 100
            }]
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.used, 0, accuracy: 0.001)
    }

    func testRemainingZero_meansHundredUsed() async throws {
        // remaining=0 → used=100 (用完)
        let json = """
        {
            "model_remains": [{
                "model_name": "general",
                "current_interval_remaining_percent": 0
            }]
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.used, 100, accuracy: 0.001)
    }

    func testUsedNeverExceedsHundred() async throws {
        // 异常情况：remaining_percent < 0（理论上不会，但服务端可能异常）
        let json = """
        {
            "model_remains": [{
                "model_name": "general",
                "current_interval_remaining_percent": -10
            }]
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.used, 100, accuracy: 0.001,
                       "remaining<0 时 used 应封顶 100，不超过 100")
    }

    func testMissingModelRemains_raisesDecodingFailed() async {
        let badJson = """
        {"base_resp": {"status_msg": "success"}}
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: badJson)
        }

        do {
            _ = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
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

    // MARK: - 端点 + 鉴权

    func testEndpoint_isCodingPlanRemains() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.host, "api.minimax.io")
            XCTAssertEqual(req.url?.path, "/v1/api/openplatform/coding_plan/remains",
                          "MiniMax 端点必须是 /v1/api/openplatform/coding_plan/remains")
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.realMiniMaxJson)
        }

        _ = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
    }

    func testBearerAuth() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer my-coding-plan-key")
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.realMiniMaxJson)
        }

        _ = try await MiniMaxProvider().fetchQuota(apiKey: "my-coding-plan-key", using: client)
    }
}
