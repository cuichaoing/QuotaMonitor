//
//  VolcengineProviderTests.swift
//  QuotaMonitorTests
//
//  验证火山 Agent Plan GetAFPUsage 响应解析（官方例子夹具）。
//  对照 CC Switch volcengine_afp_three_windows_from_official_example 单测。
//

import XCTest
@testable import QuotaMonitor

final class VolcengineProviderTests: XCTestCase {
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

    /// 把字典转成 JSON String（MockURLProtocol.jsonResponse 要 String）
    private func jsonString(_ dict: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [])
        return String(data: data, encoding: .utf8)!
    }

    /// 官方文档 GetAFPUsage 返回示例（逐字）：5h 25% / weekly 30%；AFPDaily 被跳过。
    func testAFP_threeWindows_fromOfficialExample() async throws {
        MockURLProtocol.handler = { req in
            let json: [String: Any] = [
                "ResponseMetadata": ["RequestId": "x"],
                "Result": [
                    "PlanType": "Large",
                    "AFPFiveHour": [
                        "Quota": 50.0, "Used": 12.5,
                        "SubscribeTime": 1778788800000, "ResetTime": 1778806800000
                    ],
                    "AFPDaily": [
                        "Quota": 100.0, "Used": 22.5,
                        "SubscribeTime": 1778716800000, "ResetTime": 1778803200000
                    ],
                    "AFPWeekly": [
                        "Quota": 500.0, "Used": 150.0,
                        "SubscribeTime": 1778457600000, "ResetTime": 1779062400000
                    ],
                    "AFPMonthly": [
                        "Quota": 2000.0, "Used": 850.5,
                        "SubscribeTime": 1777939200000, "ResetTime": 1780531200000
                    ]
                ]
            ]
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
        }

        let quota = try await VolcengineProvider.fetchQuota(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            dataBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3",
            using: client
        )

        // 5h 窗口：12.5 / 50 = 25%
        XCTAssertEqual(quota.provider, .volcengine)
        let primaryUsed = try XCTUnwrap(quota.primaryWindow?.usedPercent)
        XCTAssertEqual(primaryUsed, 25.0, accuracy: 0.01)
        XCTAssertEqual(quota.primaryWindow?.displayName, "5h")

        // [BUG-2026-11-07-01] 断言 resetAt 的**具体时刻**，不能只断言非 nil：
        // 旧实现把服务端的毫秒时间戳当秒用，resetAt 落到公元 5 万多年，
        // 状态栏显示「497849573 小时」、popup 显示「重置于 6,712年11个月」，
        // 而 XCTAssertNotNil 完全放行 → bug 从 v1.2.0 逃逸到线上。
        // 夹具 ResetTime = 1778806800000（毫秒）→ 2026-05-15T01:00:00Z
        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)
        XCTAssertEqual(resetAt.timeIntervalSince1970, 1_778_806_800, accuracy: 1.0,
                       "毫秒时间戳必须换算成秒，不能当成秒直接用")
        // 纵深断言：真实 5h 窗口的重置时刻必须落在近期，杜绝「几万年」类病态值再次逃逸
        XCTAssertLessThan(resetAt.timeIntervalSinceNow, 30 * 24 * 3600,
                          "重置时刻距今超过 30 天，说明时间戳单位解析错了")

        // 周窗口：150 / 500 = 30%
        let weeklyUsed = try XCTUnwrap(quota.weeklyWindow?.usedPercent)
        XCTAssertEqual(weeklyUsed, 30.0, accuracy: 0.01)
        XCTAssertEqual(quota.weeklyWindow?.displayName, "7d")
        // 周窗口 ResetTime = 1779062400000（毫秒）→ 2026-05-18T00:00:00Z
        let weeklyReset = try XCTUnwrap(quota.weeklyWindow?.resetAt)
        XCTAssertEqual(weeklyReset.timeIntervalSince1970, 1_779_062_400, accuracy: 1.0)
    }

    /// AFP Quota=0（未订阅 Agent Plan）→ 降级到 Coding Plan。
    func testAFP_zeroQuota_fallsBackToCodingPlan() async throws {
        var callCount = 0
        MockURLProtocol.handler = { req in
            callCount += 1
            // 第一次：AFP 返回 Quota=0（未订阅）
            if req.url?.query?.contains("GetAFPUsage") == true {
                let json: [String: Any] = [
                    "ResponseMetadata": ["RequestId": "x"],
                    "Result": [
                        "PlanType": "",
                        "AFPFiveHour": ["Quota": 0.0, "Used": 0.0],
                        "AFPWeekly": ["Quota": 0.0, "Used": 0.0],
                        "AFPMonthly": ["Quota": 0.0, "Used": 0.0]
                    ]
                ]
                return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
            }
            // 第二次：Coding Plan 返回 session percent
            let json: [String: Any] = [
                "ResponseMetadata": ["RequestId": "y"],
                "Result": [
                    "Status": "Running",
                    "QuotaUsage": [
                        ["Level": "session", "Percent": 12.5, "ResetTimestamp": 1782057600],
                        ["Level": "weekly", "Percent": 30.0, "ResetTimestamp": 1782057600]
                    ]
                ]
            ]
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
        }

        let quota = try await VolcengineProvider.fetchQuota(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            dataBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3",
            using: client
        )

        // 降级到 Coding Plan 后，session percent = 12.5%
        let primaryUsed = try XCTUnwrap(quota.primaryWindow?.usedPercent)
        XCTAssertEqual(primaryUsed, 12.5, accuracy: 0.01)
        let weeklyUsed = try XCTUnwrap(quota.weeklyWindow?.usedPercent)
        XCTAssertEqual(weeklyUsed, 30.0, accuracy: 0.01)
        XCTAssertEqual(callCount, 2, "应先调 AFP 再降级 Coding Plan")
    }

    /// 火山 OpenAPI 网关 host 必须是 open.volcengineapi.com（不是推理域名）
    func testEndpoint_isOpenAPIGateway() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.url?.host, "open.volcengineapi.com",
                           "火山用量查询走控制面 OpenAPI 网关，不是数据面推理域名")
            let json: [String: Any] = [
                "ResponseMetadata": ["RequestId": "z"],
                "Result": ["AFPFiveHour": ["Quota": 0.0, "Used": 0.0]]
            ]
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
        }

        do {
            _ = try await VolcengineProvider.fetchQuota(
                accessKeyId: "AKLTtest",
                secretAccessKey: "secretkey",
                dataBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3",
                using: client
            )
            XCTFail("应抛出 decodingFailed（两个 plan 都无数据）")
        } catch let err as QuotaError {
            guard case .decodingFailed = err else {
                XCTFail("期望 decodingFailed，got \(err)")
                return
            }
        }
    }

    // MARK: - [BUG-2026-11-07-01] 重置时间单位解析

    /// 火山两个接口的时间戳单位**不一致**：
    ///   - GetAFPUsage（Agent Plan）的 ResetTime = 13 位**毫秒**（实测 1794052512000）
    ///   - GetCodingPlanUsage（Coding Plan）的 ResetTimestamp = 10 位**秒**（官方示例 1782057600）
    /// 自适应判断必须两个方向都对，不能只对一边。
    func testCodingPlan_resetTime_secondTimestamp_parsedToCorrectInstant() async throws {
        MockURLProtocol.handler = { req in
            if req.url?.query?.contains("GetAFPUsage") == true {
                let json: [String: Any] = [
                    "ResponseMetadata": ["RequestId": "x"],
                    "Result": ["AFPFiveHour": ["Quota": 0.0, "Used": 0.0]]
                ]
                return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
            }
            let json: [String: Any] = [
                "ResponseMetadata": ["RequestId": "y"],
                "Result": [
                    "Status": "Running",
                    "QuotaUsage": [
                        ["Level": "session", "Percent": 12.5, "ResetTimestamp": 1782057600],
                        ["Level": "weekly", "Percent": 30.0, "ResetTimestamp": 1782057600]
                    ]
                ]
            ]
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
        }

        let quota = try await VolcengineProvider.fetchQuota(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            dataBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3",
            using: client
        )

        // 秒级时间戳必须原样使用，不能再除以 1000（否则落到 1970 年）
        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)
        XCTAssertEqual(resetAt.timeIntervalSince1970, 1_782_057_600, accuracy: 1.0,
                       "10 位秒级时间戳必须原样使用")
    }

    /// ResetTime 以**数字字符串**返回时也要正确换算。
    /// 旧实现遇到 String 就直接走 ISO8601 解析 → 数字字符串必然解析失败 → 静默 fallback 5 小时。
    func testAFP_resetTime_numericString_millisecond_parsedToCorrectInstant() async throws {
        MockURLProtocol.handler = { req in
            let json: [String: Any] = [
                "ResponseMetadata": ["RequestId": "x"],
                "Result": [
                    "PlanType": "Large",
                    "AFPFiveHour": [
                        "Quota": 50.0, "Used": 12.5,
                        "SubscribeTime": "1778788800000", "ResetTime": "1778806800000"
                    ]
                ]
            ]
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
        }

        let quota = try await VolcengineProvider.fetchQuota(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            dataBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3",
            using: client
        )

        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)
        XCTAssertEqual(resetAt.timeIntervalSince1970, 1_778_806_800, accuracy: 1.0,
                       "数字字符串形式的毫秒时间戳同样要换算成秒")
    }

    /// 纵深防御：万一服务端再改单位（或返回异常值），宁可退回「5 小时后重置」，
    /// 也不能让 UI 出现「几万年 / 6,712 年」这种病态倒计时。
    func testAFP_absurdResetTimestamp_fallsBackToFiveHours() async throws {
        MockURLProtocol.handler = { req in
            let json: [String: Any] = [
                "ResponseMetadata": ["RequestId": "x"],
                "Result": [
                    "PlanType": "Large",
                    "AFPFiveHour": [
                        "Quota": 50.0, "Used": 50.0,
                        // 15 位异常值：换算后落到公元 3 万多年
                        "SubscribeTime": 1778788800000, "ResetTime": 999999999999999
                    ]
                ]
            ]
            return MockURLProtocol.jsonResponse(url: req.url!, json: self.jsonString(json))
        }

        let quota = try await VolcengineProvider.fetchQuota(
            accessKeyId: "AKLTtest",
            secretAccessKey: "secretkey",
            dataBaseURL: "https://ark.cn-beijing.volces.com/api/plan/v3",
            using: client
        )

        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)
        XCTAssertEqual(resetAt.timeIntervalSinceNow, 5 * 3600, accuracy: 60,
                       "病态时间戳应退回「5 小时后重置」兜底，而不是几万年")
    }
}
