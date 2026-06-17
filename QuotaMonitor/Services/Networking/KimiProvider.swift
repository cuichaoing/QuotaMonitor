//
//  KimiProvider.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  Kimi Code 配额查询
//  关键约束：必须携带 User-Agent "KimiCLI/1.30.0" 才能命中 Coding Plan 专属额度
//

import Foundation

public struct KimiProvider: Provider {
    public let kind: ProviderKind = .kimi

    public init() {}

    public func fetchQuota(apiKey: String, using client: HTTPClient) async throws -> ProviderQuota {
        let url = kind.defaultBaseURL.appendingPathComponent("/coding/v1/usages")
        let request = HTTPRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "User-Agent": kind.requiredUserAgent ?? "QuotaMonitor/2.0"
            ]
        )

        let response = try await client.send(request)
        try Self.validate(response, for: kind)

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw QuotaError.decodingFailed(kind, underlying: "非 JSON 对象")
        }

        // Kimi 真实响应结构（v1.0.1 修正）：
        // {
        //   "limits": [{
        //     "detail": { "limit": "100", "used": "100", "resetTime": "..." },
        //     "window":  { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" }
        //   }, ...],
        //   "usage":     { "used": "20", "limit": "100", "remaining": "80", "resetTime": "..." },  // 周维度
        //   "totalQuota":{ "limit": "100", "remaining": "99" },
        //   ...
        // }
        // 【关键】字段值是字符串（"100"）而不是数字（100），numericValue 已兼容
        // 【关键】detail.used 直接是"已用"，不需要 limit - remaining
        guard let limits = json["limits"] as? [[String: Any]], !limits.isEmpty else {
            throw QuotaError.decodingFailed(kind, underlying: "limits 字段缺失或为空")
        }
        let first = limits[0]
        guard let detail = first["detail"] as? [String: Any] else {
            throw QuotaError.decodingFailed(kind, underlying: "limits[0].detail 字段缺失")
        }

        let limit = Self.numericValue(detail["limit"]) ?? 0
        let used = Self.numericValue(detail["used"]) ?? 0
        let resetAt = Self.parseResetTime(detail["resetTime"])
            ?? Date().addingTimeInterval(5 * 3600)

        // window.duration 单位是分钟
        let durationMin = (first["window"] as? [String: Any])
            .flatMap { Self.numericValue($0["duration"]) } ?? 300
        let displayName = "\(Int(durationMin / 60))h"

        let window = QuotaWindow(
            total: limit,
            used: used,
            resetAt: resetAt,
            displayName: displayName
        )

        return ProviderQuota(
            provider: kind,
            capturedAt: Date(),
            primaryWindow: window,
            weeklyWindow: nil,
            raw: json
        )
    }

    // MARK: - Shared Helpers (供 MiniMaxProvider 复用)

    public static func validate(_ response: HTTPResponse, for kind: ProviderKind) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw QuotaError.keyInvalid(kind)
        case 429:
            let retry = (response.headers["Retry-After"] as? String).flatMap { TimeInterval($0) }
            throw QuotaError.rateLimited(kind, retryAfter: retry)
        default:
            let msg = String(data: response.data, encoding: .utf8)
            throw QuotaError.serverError(kind, statusCode: response.statusCode, message: msg)
        }
    }

    public static func numericValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    public static func parseResetTime(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // fallback: 无小数秒
        let iso2 = ISO8601DateFormatter()
        return iso2.date(from: s)
    }
}
