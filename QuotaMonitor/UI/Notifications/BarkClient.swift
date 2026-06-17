//
//  BarkClient.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  Bark 推送：iOS 端最简 HTTP 推送协议
//  文档：https://bark.day.app/#/tutorial
//

import Foundation
import os

public struct BarkConfig: Sendable {
    public let server: URL     // e.g. https://api.day.app
    public let deviceKey: String

    public init(server: URL = URL(string: "https://api.day.app")!, deviceKey: String) {
        self.server = server
        self.deviceKey = deviceKey
    }
}

public struct BarkPayload: Sendable {
    public let title: String
    public let body: String
    public let level: AlertLevel
    public let category: String  // "quota_alert"
    public let group: String     // "QuotaMonitor"

    public init(title: String, body: String, level: AlertLevel, category: String = "quota_alert", group: String = "QuotaMonitor") {
        self.title = title
        self.body = body
        self.level = level
        self.category = category
        self.group = group
    }
}

public final class BarkClient: @unchecked Sendable {
    private let httpClient: HTTPClient
    private let logger = Logger(subsystem: "app.quotamonitor", category: "Bark")

    public init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    /// 推送单条 Bark
    /// - Throws: 网络错误或 HTTP 4xx/5xx
    public func push(_ payload: BarkPayload, using config: BarkConfig) async throws {
        var components = URLComponents(url: config.server, resolvingAgainstBaseURL: false)!
        // 路径: /{deviceKey}/{title}/{body}
        let pathTitle = payload.title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        let pathBody = payload.body.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ""
        components.path = "/\(config.deviceKey)/\(pathTitle)/\(pathBody)"

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "category", value: payload.category),
            URLQueryItem(name: "group", value: payload.group),
            URLQueryItem(name: "level", value: payload.level.barkLevel)
        ]
        if payload.level == .danger {
            queryItems.append(URLQueryItem(name: "sound", value: "alarm"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let request = HTTPRequest(url: url, method: "GET", timeout: 10)

        do {
            let response = try await httpClient.send(request)
            guard (200..<300).contains(response.statusCode) else {
                let body = String(data: response.data, encoding: .utf8) ?? ""
                logger.error("Bark push failed: HTTP \(response.statusCode, privacy: .public)")
                throw QuotaError.serverError(.kimi, statusCode: response.statusCode, message: "Bark push failed: \(body)")
            }
            logger.info("Bark push ok: \(payload.title, privacy: .public)")
        } catch let err as QuotaError {
            throw err
        } catch {
            throw QuotaError.networkUnreachable(.kimi)
        }
    }
}

private extension AlertLevel {
    /// Bark 通知优先级：active / timeSensitive / passive
    var barkLevel: String {
        switch self {
        case .danger:   return "timeSensitive"
        case .critical: return "timeSensitive"
        case .warning:  return "active"
        case .none:     return "passive"
        }
    }
}
