//
//  HTTPClient.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  极薄 URLSession 封装：复用连接 + 全 async/await + 不做重试
//

import Foundation

public struct HTTPRequest: Sendable {
    public let url: URL
    public let method: String
    public let headers: [String: String]
    public let timeout: TimeInterval

    public init(
        url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        timeout: TimeInterval = 15
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.timeout = timeout
    }
}

public struct HTTPResponse: @unchecked Sendable {
    public let statusCode: Int
    public let data: Data
    public let headers: [AnyHashable: Any]
}

/// 极薄 URLSession 包装：
/// - 复用连接（HTTP/2 / keep-alive）
/// - 全 async/await
/// - 不做重试（重试由 Provider / Service 决策）
/// - 配额数据不缓存（`.reloadIgnoringLocalCacheData`）
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession

    public init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil   // 配额数据必须实时
        self.session = URLSession(configuration: configuration)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData

        // 默认安全头
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        for (k, v) in request.headers {
            urlRequest.setValue(v, forHTTPHeaderField: k)
        }

        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return HTTPResponse(
                statusCode: http.statusCode,
                data: data,
                headers: http.allHeaderFields
            )
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw QuotaError.cancelled
        }
        // [!] 不在此处归因：HTTPClient 无状态、不感知当前请求属于哪个 provider。
        // URLError 原样冒泡，由 NetworkingService.fetchOne（持有当前 kind）归因为
        // networkUnreachable(kind)。修复 BUG-2026-06-18-01：此前硬编码 .kimi，
        // 导致 MiniMax / GLM 的网络错误被错误归到 Kimi（UI 显示 "Kimi Code 网络不可达"）。
    }
}
