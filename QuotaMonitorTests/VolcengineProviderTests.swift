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
        XCTAssertNotNil(quota.primaryWindow?.resetAt)

        // 周窗口：150 / 500 = 30%
        let weeklyUsed = try XCTUnwrap(quota.weeklyWindow?.usedPercent)
        XCTAssertEqual(weeklyUsed, 30.0, accuracy: 0.01)
        XCTAssertEqual(quota.weeklyWindow?.displayName, "7d")
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
}
