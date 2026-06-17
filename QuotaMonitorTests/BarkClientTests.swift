//
//  BarkClientTests.swift
//  QuotaMonitorTests
//
//  Bark 推送测试：URL 构造 + HTTP 调用（用 MockURLProtocol 拦截）
//

import XCTest
@testable import QuotaMonitor

final class BarkClientTests: XCTestCase {
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

    func testPush_buildsCorrectURL() async throws {
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return MockURLProtocol.jsonResponse(
                url: req.url!,
                json: "{\"code\":200,\"message\":\"success\"}"
            )
        }

        let bark = BarkClient(httpClient: client)
        let config = BarkConfig(
            server: URL(string: "https://api.day.app")!,
            deviceKey: "abc123def"
        )
        let payload = BarkPayload(
            title: "Kimi 配额告警",
            body: "已用 85%",
            level: .warning
        )

        try await bark.push(payload, using: config)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "api.day.app")
        XCTAssertTrue(url.path.contains("/abc123def/"), "路径应包含 deviceKey")
        XCTAssertTrue(url.path.contains("Kimi"), "路径应包含 title")
    }

    func testPush_dangerLevel_addsAlarmSound() async throws {
        var capturedQuery: String?
        MockURLProtocol.handler = { req in
            capturedQuery = req.url?.query
            return MockURLProtocol.jsonResponse(url: req.url!, json: "{\"code\":200}")
        }

        let bark = BarkClient(httpClient: client)
        let config = BarkConfig(deviceKey: "k")
        let payload = BarkPayload(title: "t", body: "b", level: .danger)

        try await bark.push(payload, using: config)

        XCTAssertTrue(capturedQuery?.contains("sound=alarm") ?? false,
                      "danger 等级应附带 alarm 提示音")
    }

    func testPush_4xx_throwsError() async {
        MockURLProtocol.handler = { req in
            MockURLProtocol.errorResponse(url: req.url!, statusCode: 400, headers: nil)
        }

        let bark = BarkClient(httpClient: client)
        let config = BarkConfig(deviceKey: "k")
        let payload = BarkPayload(title: "t", body: "b", level: .warning)

        do {
            try await bark.push(payload, using: config)
            XCTFail("Expected throw")
        } catch let err as QuotaError {
            if case .serverError(_, let code, _) = err {
                XCTAssertEqual(code, 400)
            } else {
                XCTFail("Expected serverError, got \(err)")
            }
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    func testPush_urlEncoding_handlesSpecialChars() async throws {
        var capturedURL: URL?
        MockURLProtocol.handler = { req in
            capturedURL = req.url
            return MockURLProtocol.jsonResponse(url: req.url!, json: "{\"code\":200}")
        }

        let bark = BarkClient(httpClient: client)
        let config = BarkConfig(deviceKey: "k")
        let payload = BarkPayload(
            title: "Kimi 配额 告警",
            body: "已用 90% 接近上限",
            level: .critical
        )

        try await bark.push(payload, using: config)

        let url = try XCTUnwrap(capturedURL)
        XCTAssertNotNil(url.path, "URL path 不应为 nil")
        let decodedPath = url.path.removingPercentEncoding ?? url.path
        XCTAssertTrue(decodedPath.contains("Kimi"), "解码后路径应含 Kimi")
    }
}
