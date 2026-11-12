//
//  BaiduUsageParser.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-11-11.
//  百度千帆 Token Plan「我的订阅」页的用量解析。
//
//  页面（console.bce.baidu.com/qianfan/resource/token-plan）登录后展示：
//     - 套餐余量 | 2026-12-11 14:51:08 重置                 ← 月套餐，到期/续费日重置
//     - Token Plan 99.08%                                  ← 剩余百分比
//     - 剩余 693,625,166 / 总量 700,000,000 Token          ← 剩余 / 总量
//
//  与 K/M/G/Z/V 的「5 小时滚动窗口」不同，千帆是「包月总量」制（非滚动窗口）。
//  映射到统一模型：used = 总量 − 剩余，resetAt = 月底重置时刻，单窗口（无周窗口）。
//

import Foundation

public enum BaiduUsageParser {
    /// 千帆重置时间 = 北京时间（控制台本地显示时区）
    static let resetTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()

    /// 把 JS 抓取返回的原始字段组装成统一配额模型。
    /// - Parameters:
    ///   - remaining: 「剩余」token 数（可能含千分位逗号，如 "693,625,166"）
    ///   - total: 「总量」token 数（如 "700,000,000"）
    ///   - remainPercent: 「剩余百分比」（如 "99.08"），作 remaining/total 缺失时的兜底
    ///   - resetAtText: 「重置」时间原文（如 "2026-12-11 14:51:08"）
    ///   - capturedAt: 抓取时刻
    /// - Returns: 组装好的快照；拿不到任何可用数字时返回 nil
    public static func parse(
        remaining: String?,
        total: String?,
        remainPercent: String?,
        resetAtText: String?,
        capturedAt: Date,
        snippet: String? = nil
    ) -> ProviderQuota? {
        let totalNum = number(total)
        let remainingNum = number(remaining)
        let resetAt = resetAtText.flatMap { resetTimeFormatter.date(from: $0) }
            ?? capturedAt.addingTimeInterval(30 * 24 * 3600)

        let window: QuotaWindow
        if let t = totalNum, t > 0, let r = remainingNum {
            // 主路径：剩余 + 总量 → 已用 = 总量 − 剩余
            window = QuotaWindow(total: t, used: max(0, t - r), resetAt: resetAt, displayName: "月")
        } else if let pct = number(remainPercent) {
            // 兜底：只拿到剩余百分比，没有 token 数 → total=100, used=100−剩余
            window = QuotaWindow(total: 100, used: max(0, min(100, 100 - pct)), resetAt: resetAt, displayName: "月")
        } else {
            return nil
        }

        return ProviderQuota(
            provider: .baidu,
            capturedAt: capturedAt,
            primaryWindow: window,
            weeklyWindow: nil,
            raw: [
                "remaining": remainingNum ?? NSNull(),
                "total": totalNum ?? NSNull(),
                "remainPercent": number(remainPercent) ?? NSNull(),
                "resetAtText": resetAtText ?? NSNull(),
                // 诊断片段：页面「余量」区块原文，解析失败时用来对正则（不含账号信息）
                "snippet": snippet ?? NSNull(),
            ]
        )
    }

    /// 从「余量」区块**原文**解析用量。
    ///
    /// [BUG-2026-11-11-02] 初版把中文正则写在 JS 里，页面文案一变（插「Token」、
    /// 全角斜杠、数字带单位）就失配且无从诊断。改为 JS 只切原文、Swift 解析。
    ///
    /// 区块长这样：
    ///   套餐余量｜2026-12-11 14:51:08 重置
    ///   限时恢复额度
    ///   Token Plan 99.08%
    ///   剩余 693,625,166 / 总量 700,000,000 Token
    public static func parse(block: String, capturedAt: Date) -> ProviderQuota? {
        let remaining = numberAfter(keyword: "剩余", in: block, skipFollowedBy: ["天", "日", "数"])
        let total = numberAfter(keyword: "总量", in: block)
        let percent = firstPercent(in: block)
        let resetText = firstDateTime(in: block)
        return parse(
            remaining: remaining,
            total: total,
            remainPercent: percent,
            resetAtText: resetText,
            capturedAt: capturedAt,
            snippet: block
        )
    }

    /// 关键词之后的第一个数字（可跳过「剩余天数 30天」这类干扰项）。
    private static func numberAfter(keyword: String, in text: String, skipFollowedBy: [String] = []) -> String? {
        var searchStart = text.startIndex
        while let kwRange = text.range(of: keyword, range: searchStart..<text.endIndex) {
            // 【关键】必须转成**独立 String** 再做正则：
            // Substring.range(of:options:) 返回的 index 与 Substring 的 index 空间不一致，
            // 会越界（Fatal error: Substring index is out of bounds）或切错片段
            // —— 实测正是这里把「剩余天数 30天」的 30 当成了剩余 token 数。
            let tail = String(text[kwRange.upperBound...])
            if let numRange = tail.range(of: #"[0-9][0-9,]*(?:\.[0-9]+)?"#, options: .regularExpression) {
                let num = String(tail[numRange])
                // 数字后面紧跟「天/日/数」→ 这是「剩余天数」之类的干扰项，继续找下一个「剩余」
                // 【注意】numRange.upperBound **就是**「数字后一个字符」的位置，不能再 index(after:) 多跳一格
                let after: String = numRange.upperBound < tail.endIndex
                    ? String(tail[numRange.upperBound])
                    : ""
                let isNoise = skipFollowedBy.contains(where: { after.hasPrefix($0) })
                if !isNoise { return num }
            }
            searchStart = kwRange.upperBound
        }
        return nil
    }

    /// 区块里第一个百分比（去掉 % 号）
    private static func firstPercent(in text: String) -> String? {
        guard let r = text.range(of: #"[0-9]+(?:\.[0-9]+)?\s*%"#, options: .regularExpression) else {
            return nil
        }
        return String(text[r])
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 区块里第一个「yyyy-MM-dd HH:mm:ss」时间（中间空格或 T 都认）
    private static func firstDateTime(in text: String) -> String? {
        guard let r = text.range(of: #"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}"#, options: .regularExpression) else {
            return nil
        }
        return String(text[r]).replacingOccurrences(of: "T", with: " ")
    }

    /// 去千分位逗号 + 去空白，转 Double。
    private static func number(_ s: String?) -> Double? {
        guard let s, !s.isEmpty else { return nil }
        let cleaned = s
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Double(cleaned)
    }

    /// 千帆月套餐按「线性均匀消耗」时，`now` 时刻应到达的已用百分比（0-100）。
    /// 周期 = resetAt 往前推一个自然月 → resetAt（月续费日，非 30 天固定）。
    /// 进度条据此画「日均应达」竖线标记，并判断实际用量是「正常（未超线）」还是「用超（超线）」。
    public static func expectedPercent(resetAt: Date, now: Date) -> Double {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        guard let periodStart = cal.date(byAdding: .month, value: -1, to: resetAt) else { return 0 }
        let total = resetAt.timeIntervalSince(periodStart)
        guard total > 0 else { return 100 }
        let elapsed = now.timeIntervalSince(periodStart)
        return min(100, max(0, elapsed / total * 100))
    }
}