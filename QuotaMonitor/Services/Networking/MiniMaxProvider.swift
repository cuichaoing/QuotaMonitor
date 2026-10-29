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

        // 【重置时间修正 v1.1.1】此前找的是不存在的字段（resetTime / interval_end_time），
        // 一律落到「抓取时刻 + 5h」兜底 → 倒计时永远显示 4 小时 59 分，与服务端窗口无关。
        // 真实响应（2026-10-29 实测）里窗口结束时刻是这三个字段：
        //   end_time        当前 5h 窗口结束时刻（毫秒时间戳，绝对时间，优先）
        //   remains_time    当前窗口剩余毫秒（相对时间，次选）
        //   weekly_end_time 周窗口结束时刻（毫秒时间戳）
        let now = Date()
        let resetAt = Self.epochMillis(primary["end_time"])
            ?? Self.relativeMillis(primary["remains_time"], from: now)
            ?? KimiProvider.parseResetTime(json["resetTime"])
            ?? now.addingTimeInterval(5 * 3600)

        let window = QuotaWindow(
            total: total,
            used: used,
            resetAt: resetAt,
            displayName: "5h"
        )

        // 周窗口（真实响应里有，之前完全没用上）：weekly_end_time + current_weekly_remaining_percent
        let weeklyWindow: QuotaWindow? = {
            guard let weeklyReset = Self.epochMillis(primary["weekly_end_time"]),
                  let weeklyRemaining = KimiProvider.numericValue(primary["current_weekly_remaining_percent"])
            else { return nil }
            return QuotaWindow(
                total: 100,
                used: max(0, min(100, 100 - weeklyRemaining)),
                resetAt: weeklyReset,
                displayName: "7d"
            )
        }()

        return ProviderQuota(
            provider: kind,
            capturedAt: now,
            primaryWindow: window,
            weeklyWindow: weeklyWindow,
            raw: json
        )
    }

    // MARK: - Helpers

    /// 毫秒时间戳 → Date（MiniMax 用 13 位毫秒；兼容 10 位秒）
    static func epochMillis(_ any: Any?) -> Date? {
        guard let ms = KimiProvider.numericValue(any) else { return nil }
        // 10 位 = 秒，13 位 = 毫秒
        let seconds = ms > 1_000_000_000_000 ? ms / 1000 : ms
        guard seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 剩余毫秒 → Date（相对时间兜底）
    static func relativeMillis(_ any: Any?, from now: Date) -> Date? {
        guard let ms = KimiProvider.numericValue(any), ms > 0 else { return nil }
        return now.addingTimeInterval(ms / 1000)
    }
}
