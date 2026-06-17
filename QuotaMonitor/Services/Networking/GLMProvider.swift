//
//  GLMProvider.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  智谱 GLM 配额查询
//  关键约束：
//   1. Authorization 头严禁带 "Bearer " 前缀，否则 401
//   2. 真实响应结构是 data.limits，不是顶层 limits
//   3. limits[i].percentage 直接是已用百分比（0-100）
//   4. limits[i].nextResetTime 是毫秒时间戳
//   5. 优先选 5h 时间窗：type="TIME_LIMIT" + unit=5
//

import Foundation

public struct GLMProvider: Provider {
    public let kind: ProviderKind = .glm

    public init() {}

    public func fetchQuota(apiKey: String, using client: HTTPClient) async throws -> ProviderQuota {
        let url = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
        let request = HTTPRequest(
            url: url,
            headers: [
                // 【关键】禁止 "Bearer " 前缀！裸 Token 直接传
                "Authorization": apiKey,
                "Content-Type": "application/json"
            ]
        )

        let response = try await client.send(request)
        try KimiProvider.validate(response, for: kind)

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw QuotaError.decodingFailed(kind, underlying: "非 JSON 对象")
        }

        // GLM 真实响应（v1.0.1 修正）：
        // {
        //   "code": 200, "success": true, "msg": "操作成功",
        //   "data": {
        //     "level": "max",
        //     "limits": [
        //       { "type": "TIME_LIMIT", "unit": 5, "number": 1,
        //         "currentValue": 388, "usage": 4000, "remaining": 3612,
        //         "percentage": 9, "nextResetTime": 1784195749973, ... },
        //       { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 0, ... },
        //       { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 32, ... }
        //     ]
        //   }
        // }
        // 【关键】数据在 data.limits，不是顶层 limits
        // 【关键】percentage 直接是已用百分比，不需要 currentValue/usage/remaining 反推
        // 【关键】nextResetTime 是毫秒时间戳，不是 ISO 8601
        guard let data = json["data"] as? [String: Any] else {
            throw QuotaError.decodingFailed(kind, underlying: "data 字段缺失")
        }
        guard let limits = data["limits"] as? [[String: Any]], !limits.isEmpty else {
            throw QuotaError.decodingFailed(kind, underlying: "limits 字段缺失或为空")
        }

        // 优先选 5h token 窗口：type="TOKENS_LIMIT" + unit=3
        // 没有 5h token 窗口时，取第一个 limit
        // 【关键 v1.0.1】用户反馈：unit=3 + TOKENS_LIMIT 才是 5h 配额
        //         unit=5 + TIME_LIMIT 是 MCP 月度额度（不要用！）
        let primary = limits.first {
            ($0["type"] as? String) == "TOKENS_LIMIT"
                && (KimiProvider.numericValue($0["unit"]) ?? 0) == 3
        } ?? limits.first

        guard let entry = primary else {
            throw QuotaError.decodingFailed(kind, underlying: "未找到可用 limit")
        }

        // percentage 直接是已用百分比（0-100）
        let percent = KimiProvider.numericValue(entry["percentage"]) ?? 0
        // unit 决定窗口大小（小时）
        let unitHours = KimiProvider.numericValue(entry["unit"]).map { Int($0) } ?? 5

        // nextResetTime 是毫秒时间戳
        let resetAt: Date = {
            if let ms = KimiProvider.numericValue(entry["nextResetTime"]) {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            // 没有重置时间，按 unitHours 推算
            return Date().addingTimeInterval(TimeInterval(unitHours) * 3600)
        }()

        let window = QuotaWindow(
            total: 100,
            used: percent,
            resetAt: resetAt,
            displayName: "\(unitHours)h"
        )

        return ProviderQuota(
            provider: kind,
            capturedAt: Date(),
            primaryWindow: window,
            raw: json
        )
    }
}
