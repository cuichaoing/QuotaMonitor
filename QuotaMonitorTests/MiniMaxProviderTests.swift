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

    // MARK: - 重置时间（v1.1.1 修正）

    /// 真实响应（2026-10-29 实测）含毫秒时间戳字段：
    ///   end_time = 当前 5h 窗口结束时刻 / remains_time = 窗口剩余毫秒
    ///   weekly_end_time = 周窗口结束时刻 / current_weekly_remaining_percent = 周剩余百分比
    private let realMiniMaxJsonWithTimes = """
    {
        "model_remains": [
            {
                "model_name": "general",
                "start_time": 1793268000000,
                "end_time": 1793286000000,
                "remains_time": 12093519,
                "current_interval_total_count": 0,
                "current_interval_usage_count": 0,
                "current_interval_remaining_percent": 99,
                "current_interval_status": 1,
                "current_weekly_total_count": 0,
                "current_weekly_usage_count": 0,
                "weekly_start_time": 1792972800000,
                "weekly_end_time": 1793577600000,
                "weekly_remains_time": 303693519,
                "current_weekly_status": 3,
                "current_weekly_remaining_percent": 100
            }
        ],
        "base_resp": {"status_msg": "success", "status_code": 0}
    }
    """

    /// 【关键回归】重置时间必须来自服务端 end_time，而不是「抓取时刻 + 5h」
    func testResetTime_usesServerEndTime_notNowPlusFiveHours() async throws {
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realMiniMaxJsonWithTimes)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)

        // end_time = 1793286000000 ms = 1793286000 s
        XCTAssertEqual(resetAt.timeIntervalSince1970, 1_793_286_000, accuracy: 1)

        // 反向断言：不能是「现在 + 5h」
        let nowPlusFiveHours = Date().addingTimeInterval(5 * 3600).timeIntervalSince1970
        XCTAssertNotEqual(resetAt.timeIntervalSince1970, nowPlusFiveHours, accuracy: 60,
                          "重置时间不能回退到 now+5h 兜底")
    }

    /// end_time 缺失时用 remains_time（相对毫秒）兜底
    func testResetTime_fallsBackToRemainsTime() async throws {
        let json = """
        {
            "model_remains": [
                {
                    "model_name": "general",
                    "remains_time": 3600000,
                    "current_interval_remaining_percent": 50
                }
            ],
            "base_resp": {"status_msg": "success", "status_code": 0}
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)
        // remains_time = 3600000 ms = 1 小时后
        XCTAssertEqual(resetAt.timeIntervalSinceNow, 3600, accuracy: 5)
    }

    /// 周窗口：weekly_end_time + current_weekly_remaining_percent
    func testWeeklyWindow_parsedFromRealFields() async throws {
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: self.realMiniMaxJsonWithTimes)
        }

        let quota = try await MiniMaxProvider().fetchQuota(apiKey: "k", using: client)
        let weekly = try XCTUnwrap(quota.weeklyWindow)
        XCTAssertEqual(weekly.displayName, "7d")
        XCTAssertEqual(weekly.usedPercent, 0, accuracy: 0.001)   // 剩余 100% → 已用 0%
        XCTAssertEqual(weekly.resetAt.timeIntervalSince1970, 1_793_577_600, accuracy: 1)
    }
}
