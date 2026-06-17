//
//  MiniMaxProvider.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-06-17.
//  MiniMax Coding Plan 配额查询
//  关键陷阱：
//   1. 必须用 Coding Plan Key（混用开放平台 Key 报 1004 错误）
//   2. current_interval_usage_count 实际是「剩余」非「已用」，需逆向相减
//   3. remains_time 在无 API 调用时也会「被动流失」，由 NetworkingService 做平滑
//

import Foundation

public struct MiniMaxProvider: Provider {
    public let kind: ProviderKind = .minimax

    public init() {}

    public func fetchQuota(apiKey: String, using client: HTTPClient) async throws -> ProviderQuota {
        let url = URL(string: "https://api.minimax.io/v1/api/openplatform/coding_plan/remains")!
        let request = HTTPRequest(
            url: url,
            headers: [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json"
            ]
        )

        let response = try await client.send(request)
        try KimiProvider.validate(response, for: kind)

        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw QuotaError.decodingFailed(kind, underlying: "非 JSON 对象")
        }

        // MiniMax 真实响应结构（v1.0.1 修正）：
        // {
        //   "model_remains": [
        //     {
        //       "model_name": "general",
        //       "current_interval_usage_count": 0,           // 已用次数（不是"剩余"）
        //       "current_interval_total_count": 0,           // 总次数
        //       "current_interval_remaining_percent": 55,    // 剩余百分比（55% 剩 = 45% 用）
        //       "current_interval_status": 1,
        //       ...
        //     },
        //     { "model_name": "video", ... }
        //   ]
        // }
        // 【关键反直觉点 v1.0.1】：
        //   - current_interval_usage_count 是"已用次数"，不是 v0.1 假设的"剩余"
        //   - current_interval_remaining_percent 是"剩余百分比"
        //   - model_remains 是数组（按 model 分组），需选主 model
        guard let modelRemains = json["model_remains"] as? [[String: Any]], !modelRemains.isEmpty else {
            throw QuotaError.decodingFailed(kind, underlying: "model_remains 字段缺失或为空")
        }

        // 选主 model：优先 "general"（Coding Plan 主用模型），否则第一个
        let primary = modelRemains.first { ($0["model_name"] as? String) == "general" }
            ?? modelRemains[0]

        // 从 remaining_percent 反算 usedPercent
        // 例子：remaining=55 → usedPercent = 100 - 55 = 45
        let remainingPercent = KimiProvider.numericValue(primary["current_interval_remaining_percent"]) ?? 100
        let usedPercent = max(0, min(100, 100 - remainingPercent))

        // 百分比模式下 total 固定 100
        let total = 100.0
        let used = usedPercent

        // resetTime 字段可能不在顶层（在新版本中可能移到 model_remains[i] 里）
        // 暂时用 5h 默认值，未来根据真实响应再调整
        let resetAt = KimiProvider.parseResetTime(json["resetTime"])
            ?? KimiProvider.parseResetTime(primary["interval_end_time"])
            ?? Date().addingTimeInterval(5 * 3600)

        let window = QuotaWindow(
            total: total,
            used: used,
            resetAt: resetAt,
            displayName: "5h"
        )

        return ProviderQuota(
            provider: kind,
            capturedAt: Date(),
            primaryWindow: window,
            raw: json
        )
    }
}
