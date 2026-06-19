//
//  GLMProviderTests.swift
//  QuotaMonitorTests
//
//  验证 GLM 的"裸 Token"鉴权 + 真实响应结构 (data.limits) + 5h 窗口选择
//  v1.0.1 更新：响应结构改为 data.limits 数组 + percentage 直接给百分比
//

import XCTest
@testable import QuotaMonitor

final class GLMProviderTests: XCTestCase {
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

    // MARK: - 鉴权头防坑

    func testAuthorization_isRawToken_withoutBearerPrefix() async throws {
        // 【关键】GLM 禁止 "Bearer " 前缀，必须是裸 Token
        var capturedAuth: String?
        MockURLProtocol.handler = { req in
            capturedAuth = req.value(forHTTPHeaderField: "Authorization")
            let json = Self.realGLMJson(percent5h: 23.4)
            return MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        _ = try await GLMProvider().fetchQuota(apiKey: "my-raw-glm-token", using: client)

        XCTAssertEqual(capturedAuth, "my-raw-glm-token",
                       "GLM Authorization 必须是裸 Token")
        XCTAssertFalse(capturedAuth?.hasPrefix("Bearer ") ?? false,
                       "绝不能加 Bearer 前缀，否则智谱服务端 401")
    }

    func testEndpoint_isApiMonitorUsageQuotaLimit() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.host, "api.z.ai",
                          "GLM 端点必须用 api.z.ai（新域）而不是 bigmodel.cn（旧域）")
            XCTAssertEqual(req.url?.path, "/api/monitor/usage/quota/limit")
            // 空 limits 期望 throws decodingFailed
            return MockURLProtocol.jsonResponse(url: req.url!, json: "{\"code\":200,\"success\":true,\"data\":{\"limits\":[]}}")
        }

        do {
            _ = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
            XCTFail("Expected throw on empty limits")
        } catch let err as QuotaError {
            guard case .decodingFailed = err else {
                XCTFail("Expected decodingFailed, got \(err)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - 百分比解析（v1.0.1 真实响应结构）

    func testDirectPercentParsing() async throws {
        // percentage 直接是已用百分比
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: Self.realGLMJson(percent5h: 75.0))
        }

        let quota = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.usedPercent, 75, accuracy: 0.001)
        XCTAssertEqual(window.used, 75, accuracy: 0.001)
        XCTAssertEqual(window.remaining, 25, accuracy: 0.001,
                       "remaining = 100 - usedPercent (因 total=100)")
    }

    func testPrefers5HourTokenLimit() async throws {
        // 当多 limit 维度时，优先 TOKENS_LIMIT + unit=3（5h 配额窗口）
        // 【关键 v1.0.1】用户反馈：网页第一个百分比（5h 配额）= TOKENS_LIMIT + unit=3
        //                TIME_LIMIT + unit=5 是 MCP 月度额度，不要用
        let json = """
        {
            "code": 200,
            "success": true,
            "data": {
                "limits": [
                    { "type": "TIME_LIMIT",   "unit": 5, "percentage": 9.0, "nextResetTime": 1784195749973 },
                    { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 0.0 },
                    { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 32.0 }
                ]
            }
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.usedPercent, 0.0, accuracy: 0.001,
                       "应优先匹配 TOKENS_LIMIT + unit=3 的 5h 配额窗口（0%），不是 TIME_LIMIT+unit=5 的 MCP 月度（9%）")
        XCTAssertEqual(window.displayName, "5h",
                       "unit=3 是 5h 窗口类型枚举（非小时数），displayName 应为 5h")
    }

    func testFallsBackToFirstLimitWhenNo5Hour() async throws {
        // 没有 TOKENS_LIMIT+unit=3 时，取第一个 limit
        let json = """
        {
            "code": 200,
            "success": true,
            "data": {
                "limits": [
                    { "type": "TOKENS_LIMIT", "unit": 7, "percentage": 42.0 }
                ]
            }
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.usedPercent, 42, accuracy: 0.001)
        XCTAssertEqual(window.displayName, "5h",
                       "unit=7 是未知类型，displayName 兜底为 5h（GLM 主窗口语义）")
    }

    func testNextResetTime_isMillisecondTimestamp() async throws {
        // nextResetTime 是毫秒时间戳，需正确解析
        // 1784195749973 ms = 2026-06-17 07:15:49 UTC (大约)
        // 注意：5h 配额 limit (TOKENS_LIMIT+unit=3) 真实响应里没有 nextResetTime，
        //       此测试用 fallback 行为：缺失时按 unitHours 推算
        let json = """
        {
            "code": 200,
            "success": true,
            "data": {
                "limits": [
                    { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 0.0 }
                ]
            }
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        // 缺失 nextResetTime -> fallback: now + 5h（unit=3 是 5h 窗口，非 3h）
        let delta = abs(window.resetAt.timeIntervalSinceNow - 5 * 3600)
        XCTAssertLessThan(delta, 5.0, "缺失 nextResetTime 时按真实窗口时长（unit=3 → 5h）推算 resetAt")
    }

    func testNextResetTime_presentOnMcpMonthlyLimit() async throws {
        // 验证 5h limit 没 nextResetTime 时不影响主窗口解析
        // 把 nextResetTime 放在 MCP 月度 limit 上（不参与 primary 选择）
        let json = """
        {
            "code": 200,
            "success": true,
            "data": {
                "limits": [
                    { "type": "TIME_LIMIT",   "unit": 5, "percentage": 9.0, "nextResetTime": 1784195749973 },
                    { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 0.0 }
                ]
            }
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let quota = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
        let window = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(window.usedPercent, 0.0, accuracy: 0.001,
                       "主窗口应该是 5h 配额 (unit=3) 的 0%")
        XCTAssertEqual(window.displayName, "5h")
    }

    func testMissingDataField_raisesDecodingFailed() async {
        // 没有 data 字段（旧 v0.1 格式：顶层 limits）应 throws decodingFailed
        let badJson = """
        {
            "code": 200,
            "success": true,
            "limits": [
                { "type": "TIME_LIMIT", "unit": 5, "percentage": 30.0 }
            ]
        }
        """
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(url: req.url!, json: badJson)
        }

        do {
            _ = try await GLMProvider().fetchQuota(apiKey: "k", using: client)
            XCTFail("Expected throw on missing data field")
        } catch let err as QuotaError {
            guard case .decodingFailed = err else {
                XCTFail("Expected decodingFailed, got \(err)")
                return
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Helpers

    /// 生成 GLM 真实响应格式（data.limits 数组）
    /// 5h 配额 = TOKENS_LIMIT + unit=3
    /// 周配额 = TOKENS_LIMIT + unit=6
    /// MCP 月度 = TIME_LIMIT + unit=5（不用）
    private static func realGLMJson(percent5h: Double) -> String {
        """
        {
            "code": 200,
            "success": true,
            "msg": "操作成功",
            "data": {
                "level": "max",
                "limits": [
                    { "type": "TIME_LIMIT",   "unit": 5, "number": 1, "percentage": 9,  "nextResetTime": 1784195749973 },
                    { "type": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": \(percent5h) },
                    { "type": "TOKENS_LIMIT", "unit": 6, "number": 1, "percentage": 32 }
                ]
            }
        }
        """
    }
}
