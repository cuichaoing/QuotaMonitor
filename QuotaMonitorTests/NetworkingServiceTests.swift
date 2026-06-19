//
//  NetworkingServiceTests.swift
//  QuotaMonitorTests
//
//  验证并行抓取 + 数据平滑 + Key 缺失处理
//

import XCTest
@testable import QuotaMonitor

final class NetworkingServiceTests: XCTestCase {
    var mockKeychain: InMemoryKeychainStore!
    var client: HTTPClient!

    override func setUp() {
        super.setUp()
        mockKeychain = InMemoryKeychainStore()
        client = MockURLProtocol.makeHTTPClient()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - 并行抓取

    func testFetchAll_threePlatforms_inParallel() async throws {
        try mockKeychain.save("k1", for: .kimi)
        try mockKeychain.save("m1", for: .minimax)
        try mockKeychain.save("g1", for: .glm)

        // 用 sleep 模拟网络延迟，验证是否真的并行
        // 按 host 分流 mock：3 平台响应格式不同（v1.0.1 用真实 API 格式）
        let perRequestDelay: TimeInterval = 0.2
        MockURLProtocol.handler = { req in
            try? await Task.sleep(nanoseconds: UInt64(perRequestDelay * 1_000_000_000))
            let host = req.url?.host ?? ""
            let json: String
            switch host {
            case "api.kimi.com":
                json = """
                {"limits":[{"detail":{"limit":"100","used":"50","resetTime":"2026-06-17T20:00:00Z"},"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}
                """
            case "api.minimax.io":
                json = """
                {"model_remains":[{"model_name":"general","current_interval_remaining_percent":50}]}
                """
            case "api.z.ai":
                // v1.0.1 mock：GLM 真实响应 data.limits 格式
                json = "{\"code\":200,\"success\":true,\"data\":{\"limits\":[{\"type\":\"TIME_LIMIT\",\"unit\":5,\"percentage\":30.0}]}}"
            default:
                json = "{}"
            }
            return MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)
        let start = Date()
        let results = await service.fetchAll()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(results.count, 3)

        // 串行需要 ~0.6s，并行应该 < 0.5s
        XCTAssertLessThan(elapsed, 0.5,
                          "3 平台应并行抓取，串行需要 ~\(perRequestDelay * 3)s，实际耗时 \(elapsed)s")

        for kind in [ProviderKind.kimi, .minimax, .glm] {
            XCTAssertNoThrow(try results[kind]?.get(),
                            "\(kind) 应有成功结果")
        }
    }

    // MARK: - Key 缺失

    func testKeyMissing_returnsError() async throws {
        // 故意不写入任何 Key
        let service = NetworkingService(keychain: mockKeychain, httpClient: client)
        let results = await service.fetchAll([.kimi])

        let result = try XCTUnwrap(results[.kimi])
        guard case .failure(let err) = result else {
            XCTFail("Expected failure")
            return
        }
        XCTAssertTrue(err.isUserActionable, "Key 缺失应引导去设置页")
    }

    func testOnlyConfiguredPlatforms_returned() async throws {
        try mockKeychain.save("k1", for: .kimi)
        // MiniMax / GLM 不配置

        // 必须为 Kimi 设置 handler，否则 Kimi 也会因 networkUnreachable 失败
        // v1.0.1 mock：嵌套 limits[0].detail.used
        MockURLProtocol.handler = { req in
            MockURLProtocol.jsonResponse(
                url: req.url!,
                json: "{\"limits\":[{\"detail\":{\"limit\":\"1\",\"used\":\"1\",\"resetTime\":\"2026-06-17T20:00:00Z\"},\"window\":{\"duration\":300,\"timeUnit\":\"TIME_UNIT_MINUTE\"}}]}"
            )
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)
        let results = await service.fetchAll([.kimi, .minimax, .glm])

        XCTAssertNoThrow(try results[.kimi]?.get())
        XCTAssertThrowsError(try results[.minimax]?.get())
        XCTAssertThrowsError(try results[.glm]?.get())
    }

    // MARK: - 数据平滑

    func testSmoothing_preventsDecreaseWithinSameWindow() async throws {
        try mockKeychain.save("k1", for: .kimi)

        // v1.0.1 mock：Kimi 真实响应格式，detail.used 直接是已用
        var usedValue: Double = 60
        MockURLProtocol.handler = { req in
            let json = """
            {"limits":[{"detail":{"limit":"100","used":"\(Int(usedValue))","resetTime":"2026-06-17T20:00:00Z"},"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}
            """
            return MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)

        // 第一次抓取：used=60
        usedValue = 60
        let r1 = await service.fetchAll([.kimi])
        let q1 = try XCTUnwrap(r1[.kimi]).get()
        let w1 = try XCTUnwrap(q1.primaryWindow)
        XCTAssertEqual(w1.used, 60, accuracy: 0.001)

        // 第二次抓取：used=40（倒退）
        usedValue = 40
        let r2 = await service.fetchAll([.kimi])
        let q2 = try XCTUnwrap(r2[.kimi]).get()
        let w2 = try XCTUnwrap(q2.primaryWindow)
        XCTAssertEqual(w2.used, 60, accuracy: 0.001,
                       "同窗口内 used 不应倒退，平滑保留上一次的 60")
    }

    func testSmoothing_allowsIncrease() async throws {
        try mockKeychain.save("k1", for: .kimi)

        // v1.0.1 mock：Kimi 真实响应格式
        var usedValue: Double = 30
        MockURLProtocol.handler = { req in
            let json = """
            {"limits":[{"detail":{"limit":"100","used":"\(Int(usedValue))","resetTime":"2026-06-17T20:00:00Z"},"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}
            """
            return MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)

        // 第一次 used=30
        usedValue = 30
        let r1 = await service.fetchAll([.kimi])
        let w1 = try XCTUnwrap(try XCTUnwrap(r1[.kimi]).get().primaryWindow)
        XCTAssertEqual(w1.used, 30, accuracy: 0.001)

        // 第二次 used=70（增加，正常通过）
        usedValue = 70
        let r2 = await service.fetchAll([.kimi])
        let w2 = try XCTUnwrap(try XCTUnwrap(r2[.kimi]).get().primaryWindow)
        XCTAssertEqual(w2.used, 70, accuracy: 0.001,
                       "同窗口内 used 增加是正常消耗，应通过")
    }

    // MARK: - 数据平滑（BUG-2026-06-19-01：窗口重置后的合法下降不得被卡住）

    func testSmoothing_acceptsLowerValueWhenServerWindowResets() async throws {
        // 复现真实 bug：GLM 上窗口 used=13，服务端窗口重置后新窗口真实 used=3。
        // 旧实现按 capturedAt 切指纹，两次抓取落在同一桶 → 平滑判定「3 < 13 = 倒退」→ 卡住 13。
        // 修复后指纹锚定 resetAt，窗口重置（nextResetTime 推进）→ 指纹变 → 不平滑 → 接受 3。
        try mockKeychain.save("g1", for: .glm)

        var percentage: Double = 13
        var nextResetMs: Int64 = 1_750_300_000_000      // 旧窗口重置点（毫秒）
        MockURLProtocol.handler = { req in
            let json = """
            {"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"percentage":\(percentage),"nextResetTime":\(nextResetMs)}]}}
            """
            return MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)

        // 第一次：上窗口 used=13
        percentage = 13
        nextResetMs = 1_750_300_000_000
        let r1 = await service.fetchAll([.glm])
        let w1 = try XCTUnwrap(try XCTUnwrap(r1[.glm]).get().primaryWindow)
        XCTAssertEqual(w1.used, 13, accuracy: 0.001)

        // 第二次：服务端窗口已重置（nextResetTime 推进 5h），新窗口真实 used=3
        percentage = 3
        nextResetMs = 1_750_318_000_000                  // +5h
        let r2 = await service.fetchAll([.glm])
        let w2 = try XCTUnwrap(try XCTUnwrap(r2[.glm]).get().primaryWindow)
        XCTAssertEqual(w2.used, 3, accuracy: 0.001,
                       "窗口重置后 used 从 13 跌到 3 是合法的，平滑不得保留旧值 13（BUG-2026-06-19-01）")
    }

    func testSmoothing_attachesInfoWhenRetainingPreviousValue() async throws {
        // 同窗口（同 resetAt）下 used 倒退 → 平滑保留旧值，且须在结果上标记
        // smoothing.applied=true + rawUsedPercent=本次被丢弃的真实值（v1.0.10 诊断升级）
        try mockKeychain.save("k1", for: .kimi)

        var usedValue: Double = 60
        MockURLProtocol.handler = { req in
            let json = """
            {"limits":[{"detail":{"limit":"100","used":"\(Int(usedValue))","resetTime":"2026-06-17T20:00:00Z"},"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"}}]}
            """
            return MockURLProtocol.jsonResponse(url: req.url!, json: json)
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)

        usedValue = 60
        _ = await service.fetchAll([.kimi])

        usedValue = 40   // 同窗口倒退
        let r2 = await service.fetchAll([.kimi])
        let q2 = try XCTUnwrap(try XCTUnwrap(r2[.kimi]).get())
        let smoothing = try XCTUnwrap(q2.smoothing, "被平滑保留的快照应携带 smoothing 信息")
        XCTAssertEqual(smoothing.applied, true)
        let rawUsed = try XCTUnwrap(smoothing.rawUsedPercent, "applied=true 时应有 rawUsedPercent")
        XCTAssertEqual(rawUsed, 40, accuracy: 0.001,
                       "rawUsedPercent 应是被丢弃的本次真实值 40")
    }

    // MARK: - 网络错误归因（BUG-2026-06-18-01 根因 A）
    // 修复前 HTTPClient 把所有 URLError 硬编码成 networkUnreachable(.kimi)，
    // 导致 MiniMax / GLM 的网络错误被错误归因到 Kimi（UI 显示 "Kimi Code 网络不可达"）。

    func testNetworkError_attributedToCallingProvider_notHardcodedKimi() async throws {
        try mockKeychain.save("m1", for: .minimax)
        try mockKeychain.save("g1", for: .glm)

        // 模拟传输层失败：所有请求都抛 URLError
        MockURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }

        let service = NetworkingService(keychain: mockKeychain, httpClient: client)
        let results = await service.fetchAll([.minimax, .glm])

        // MiniMax 的网络错误必须归因到 .minimax（修复前会被钉死成 .kimi）
        let minimaxResult = try XCTUnwrap(results[.minimax])
        guard case .failure(let minimaxErr) = minimaxResult else {
            XCTFail("MiniMax 在网络错误时应失败"); return
        }
        guard case .networkUnreachable(let minimaxKind, _) = minimaxErr else {
            XCTFail("MiniMax 网络错误应为 networkUnreachable，实际：\(minimaxErr)"); return
        }
        XCTAssertEqual(minimaxKind, .minimax,
                       "MiniMax 网络错误必须归因到 minimax，不应硬编码成 kimi")

        // GLM 同理
        let glmResult = try XCTUnwrap(results[.glm])
        guard case .failure(let glmErr) = glmResult else {
            XCTFail("GLM 在网络错误时应失败"); return
        }
        guard case .networkUnreachable(let glmKind, _) = glmErr else {
            XCTFail("GLM 网络错误应为 networkUnreachable，实际：\(glmErr)"); return
        }
        XCTAssertEqual(glmKind, .glm,
                       "GLM 网络错误必须归因到 glm，不应硬编码成 kimi")
    }
}

// MARK: - XCTAssertThrowsError helper removed
// 标准 XCTAssertThrowsError 已能处理 Result<>.get() 抛错
