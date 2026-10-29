//
//  GeminiUsageParser.swift
//  QuotaMonitor
//
//  Created by AgentForge on 2026-10-29.
//  Gemini 订阅用量页（gemini.google.com/usage）DOM 解析器。
//  纯函数、无 UI 依赖，可用真实 DOM 快照做单测。
//
//  页面结构（2026-10-29 实测，data-testid 为 Google 自家测试锚点）：
//    <li data-testid="current-usage">
//      <strong>当前用量</strong>
//      <strong>已使用 31%</strong>
//      <span>重置时间：13:01</span>          ← 当天或次日时刻
//    </li>
//    <li data-testid="weekly-usage">
//      <strong>每周限额</strong>
//      <span>重置时间：11月2日16:01</span>    ← 月日 + 时刻（无年份）
//      <strong>已使用 3%</strong>
//    </li>
//
//  提取候选链（防改版）：
//    1. data-testid 块内「已使用 X%」文本
//    2. 块内进度条内联样式 --x-width: X%（语言无关，英文 UI 也适用）
//

import Foundation

/// 一次成功抓取的 Gemini 用量快照（解析产物）
public struct GeminiUsagePage: Sendable, Equatable {
    /// 当前用量窗口已用百分比（页面主窗口，对应 ProviderQuota.primaryWindow）
    public let currentUsedPercent: Double?
    /// 当前窗口重置时间原文（如 "13:01"）
    public let currentResetText: String?
    /// 每周限额窗口已用百分比
    public let weeklyUsedPercent: Double?
    /// 每周窗口重置时间原文（如 "11月2日16:01"）
    public let weeklyResetText: String?

    public init(
        currentUsedPercent: Double?,
        currentResetText: String?,
        weeklyUsedPercent: Double?,
        weeklyResetText: String?
    ) {
        self.currentUsedPercent = currentUsedPercent
        self.currentResetText = currentResetText
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyResetText = weeklyResetText
    }

    public var hasAnyValue: Bool {
        currentUsedPercent != nil || weeklyUsedPercent != nil
    }
}

public enum GeminiUsageParser {

    /// 从 usage 页 HTML 中提取两窗口用量。
    /// 输入可为整页 outerHTML 或仅两个 <li> 块的片段。
    public static func parse(html: String) -> GeminiUsagePage {
        let current = extractBlock(html, testid: "current-usage")
        let weekly = extractBlock(html, testid: "weekly-usage")
        return GeminiUsagePage(
            currentUsedPercent: usedPercent(in: current),
            currentResetText: resetText(in: current),
            weeklyUsedPercent: usedPercent(in: weekly),
            weeklyResetText: resetText(in: weekly)
        )
    }

    /// 解析「重置时间」原文为具体时刻。
    /// 支持两种实测格式：
    ///   - "13:01"            → 最近的未来时刻（已过则次日）
    ///   - "11月2日16:01"     → 月日+时刻；解析出的日期若已过去超过 3 天则视为次年
    ///     （周窗口重置最远 7 天，跨年场景只有 12 月底 → 1 月初，
    ///      「过去超过 3 天」判次年可同时容纳时区/时钟小幅偏差）
    /// 不识别的格式返回 nil（倒计时 UI 显示原文）。
    public static func parseResetTime(_ text: String, now: Date = Date(), timeZone: TimeZone = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // 格式一：M月d日HH:mm（容忍 "11月2日16:01" / "11月2日 16:01"）
        if let m = match(pattern: #"(\d{1,2})月(\d{1,2})日\s*(\d{1,2}):(\d{2})"#, in: trimmed) {
            let month = m[0], day = m[1], hour = m[2], minute = m[3]
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            for yearOffset in [0, 1] {
                let year = cal.component(.year, from: now) + yearOffset
                if let date = cal.date(from: DateComponents(
                    year: year, month: month, day: day, hour: hour, minute: minute)) {
                    // 取「距今最近且不早于 3 天前」的候选
                    if date.timeIntervalSince(now) > -3 * 86400 {
                        return date
                    }
                }
            }
            return nil
        }

        // 格式二：HH:mm（当天或次日）
        if let m = match(pattern: #"(\d{1,2}):(\d{2})"#, in: trimmed) {
            let hour = m[0], minute = m[1]
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = timeZone
            let today = cal.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
            return today > now ? today : cal.date(byAdding: .day, value: 1, to: today) ?? today
        }

        return nil
    }

    // MARK: - 私有

    /// 抠出 data-testid 块（<li data-testid="X"> ... </li>，块内无嵌套 li）
    private static func extractBlock(_ html: String, testid: String) -> Substring? {
        guard let r = html.range(of: #"data-testid="\#(testid)""#, options: .regularExpression),
              // data-testid 属性就在 <li 标签内，块起点在匹配位置之前 → 向前回溯找最近的 "<li"
              let tagStart = html.range(of: "<li", options: .backwards, range: html.startIndex..<r.lowerBound),
              let end = html.range(of: "</li>", range: r.lowerBound..<html.endIndex) else {
            return nil
        }
        return html[tagStart.lowerBound..<end.upperBound]
    }

    /// 候选链提取已用百分比：
    /// 1.「已使用 31%」/ "Used 31%" 等本地化文本（取块内最后一个百分比，规避标题里的无关数字）
    /// 2. 进度条内联样式 --x-width: 31%（语言无关兜底）
    private static func usedPercent(in block: Substring?) -> Double? {
        guard let block else { return nil }
        if let pct = lastPercent(matching: #"(?:已使用|Used|已用)\s*[:：]?\s*([\d.]+)\s*%"#, in: block) {
            return pct
        }
        // 兜底：宽松取「已使用/Used」后任意数字；再兜底 --x-width
        if let pct = lastPercent(matching: #"(?:已使用|Used)\s*([\d.]+)"#, in: block) {
            return pct
        }
        if let pct = lastPercent(matching: #"--x-width:\s*([\d.]+)%"#, in: block) {
            return pct
        }
        return nil
    }

    private static func resetText(in block: Substring?) -> String? {
        guard let block else { return nil }
        // 「重置时间：13:01」全角冒号；兼容 "Resets at 13:01"
        // 捕获组排除标签与引号边界，容许中文数字冒号空格
        let pattern = #"(?:重置时间|重置|Resets?\s*(?:at)?)\s*[:：]?\s*([0-9月日时:： ]{2,24})"#
        if let m = firstCapture(pattern, in: block) {
            let cleaned = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// 取块内所有匹配中的最后一个百分比（「已使用」文本通常在标题之后）
    private static func lastPercent(matching pattern: String, in block: Substring) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(block.startIndex..., in: block)
        var last: Double?
        regex.enumerateMatches(in: String(block), range: range) { m, _, _ in
            guard let m, m.numberOfRanges > 1,
                  let r = Range(m.range(at: 1), in: block),
                  let v = Double(block[r]) else { return }
            last = v
        }
        return last.map { min(max($0, 0), 100) }
    }

    private static func firstCapture(_ pattern: String, in block: Substring) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: String(block), range: NSRange(block.startIndex..., in: block)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: block) else { return nil }
        return String(block[r])
    }

    private static func match(pattern: String, in text: String) -> [Int]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        // 跳过整体匹配，取所有捕获组
        var result: [Int] = []
        for i in 1..<m.numberOfRanges {
            guard let r = Range(m.range(at: i), in: text) else { continue }
            result.append(Int(text[r]) ?? 0)
        }
        return result.isEmpty ? nil : result
    }
}
