//
//  MockURLProtocol.swift
//  QuotaMonitorTests
//
//  URLProtocol 拦截器：mock 三个平台的 HTTP 响应
//

import Foundation
import XCTest
@testable import QuotaMonitor

final class MockURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) async -> (HTTPURLResponse, Data?)

    /// 当前测试期望的响应处理（async，支持 Task.sleep 模拟网络延迟）
    static var handler: Handler?

    /// 已拦截的请求（用于断言 URL / Header / Method）
    static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.capturedRequests.append(request)

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        // URLProtocol 是 NSObject，client 是 NSURLProtocolClient。
        // 用 Task.detached 避免继承调用方 actor（URLSession.data 的 actor），
        // 保证 3 个并发请求的 sleep 能真正并行（而非串行）。
        Task.detached { [self] in
            let (response, data) = await handler(self.request)
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if let data = data {
                self.client?.urlProtocol(self, didLoad: data)
            }
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    // MARK: - Helper

    /// 创建注入 mock 的 HTTPClient
    static func makeHTTPClient() -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return HTTPClient(configuration: config)
    }

    /// 200 OK + JSON
    static func jsonResponse(url: URL, json: String) -> (HTTPURLResponse, Data?) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, data)
    }

    /// 错误状态码
    static func errorResponse(url: URL, statusCode: Int, headers: [String: String]? = nil) -> (HTTPURLResponse, Data?) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, Data())
    }

    /// 清理状态
    static func reset() {
        handler = nil
        capturedRequests.removeAll()
    }
}
