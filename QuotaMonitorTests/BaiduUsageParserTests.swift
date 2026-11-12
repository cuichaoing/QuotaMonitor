//
//  BaiduUsageParserTests.swift
//  QuotaMonitorTests
//
//  验证百度千帆 Token Plan「我的订阅」页指标的解析与映射。
//

import XCTest
@testable import QuotaMonitor

final class BaiduUsageParserTests: XCTestCase {

    /// 主路径：剩余 + 总量 → 已用 = 总量 − 剩余
    func testParse_remainingAndTotal() throws {
        let quota = try XCTUnwrap(BaiduUsageParser.parse(
            remaining: "693,625,166",
            total: "700,000,000",
            remainPercent: "99.08",
            resetAtText: "2026-12-11 14:51:08",
            capturedAt: Date()))

        XCTAssertEqual(quota.provider, .baidu)
        let w = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(w.total, 700_000_000, accuracy: 0.001)
        XCTAssertEqual(w.used, 6_374_834, accuracy: 0.001)
        // 已用 ≈ 0.91%（千帆显示的是「剩余 99.08%」，QuotaMonitor 语义是「已用」）
        XCTAssertEqual(w.usedPercent, 0.9107, accuracy: 0.01)
        XCTAssertEqual(w.displayName, "月")
        XCTAssertNil(quota.weeklyWindow, "千帆是包月单窗口，无周窗口")
    }

    /// 重置时间按北京时间（Asia/Shanghai）解析，不能漂到本地/UTC 造成时差
    func testParse_resetTime_BeijingTimezone() throws {
        let quota = try XCTUnwrap(BaiduUsageParser.parse(
            remaining: "0",
            total: "700,000,000",
            remainPercent: nil,
            resetAtText: "2026-12-11 14:51:08",
            capturedAt: Date()))
        let resetAt = try XCTUnwrap(quota.primaryWindow?.resetAt)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: resetAt)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 12)
        XCTAssertEqual(c.day, 11)
        XCTAssertEqual(c.hour, 14)
        XCTAssertEqual(c.minute, 51)
        XCTAssertEqual(c.second, 8)
    }

    /// 兜底：只有剩余百分比（页面 token 数字没抓到）→ total=100, used=100−剩余
    func testParse_remainPercentFallback() throws {
        let quota = try XCTUnwrap(BaiduUsageParser.parse(
            remaining: nil,
            total: nil,
            remainPercent: "99.08",
            resetAtText: nil,
            capturedAt: Date()))
        let w = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(w.total, 100, accuracy: 0.001)
        XCTAssertEqual(w.used, 100 - 99.08, accuracy: 0.01)
    }

    /// 拿不到任何数字 → 返回 nil（调用方降级为「解析失败」）
    func testParse_空输入返回nil() {
        XCTAssertNil(BaiduUsageParser.parse(
            remaining: nil, total: nil, remainPercent: nil,
            resetAtText: nil, capturedAt: Date()))
    }

    /// 千分位逗号 + 前后空白都要容错
    func testParse_去逗号容错() throws {
        let quota = try XCTUnwrap(BaiduUsageParser.parse(
            remaining: " 693,625,166 ",
            total: " 700,000,000 ",
            remainPercent: nil,
            resetAtText: nil,
            capturedAt: Date()))
        let w = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(w.total, 700_000_000, accuracy: 0.001)
        XCTAssertEqual(w.used, 6_374_834, accuracy: 0.001)
    }

    // MARK: - 区块原文解析（JS 切原文 → Swift 解析）

    /// 真实页面文案（2026-11-11 截图 OCR 重建）
    private let realBlock = """
    套餐余量｜2026-12-11 14:51:08 重置
    限时恢复额度
    Token Plan 99.08%
    剩余 693,625,166 / 总量 700,000,000 Token
    """

    func testParseBlock_真实页面文案() throws {
        let quota = try XCTUnwrap(BaiduUsageParser.parse(block: realBlock, capturedAt: Date()))
        let w = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(w.total, 700_000_000, accuracy: 0.001)
        XCTAssertEqual(w.used, 6_374_834, accuracy: 0.001)
        XCTAssertEqual(w.usedPercent, 0.9107, accuracy: 0.01)
        XCTAssertEqual(w.displayName, "月")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day, .hour], from: w.resetAt)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 12)
        XCTAssertEqual(c.day, 11)
        XCTAssertEqual(c.hour, 14)
    }

    /// 数字后面插「Token」单位（初版 JS 正则就是死在这上面）
    func testParseBlock_数字后带Token单位() throws {
        let block = """
        套餐余量｜2026-12-11 14:51:08 重置
        剩余 693,625,166 Token / 总量 700,000,000 Token
        """
        let quota = try XCTUnwrap(BaiduUsageParser.parse(block: block, capturedAt: Date()))
        let w = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(w.total, 700_000_000, accuracy: 0.001)
        XCTAssertEqual(w.used, 6_374_834, accuracy: 0.001)
    }

    /// 区块里混进「剩余天数 30 天」不能被当成「剩余 token 数」
    func testParseBlock_跳过剩余天数干扰项() throws {
        let block = """
        剩余天数 30天
        到期时间 2026-12-11 14:51:08
        套餐余量｜2026-12-11 14:51:08 重置
        剩余 693,625,166 / 总量 700,000,000 Token
        """
        let quota = try XCTUnwrap(BaiduUsageParser.parse(block: block, capturedAt: Date()))
        let w = try XCTUnwrap(quota.primaryWindow)
        XCTAssertEqual(w.total, 700_000_000, accuracy: 0.001)
        XCTAssertEqual(w.used, 6_374_834, accuracy: 0.001)
    }

    /// 区块里没有可用数字 → 返回 nil（调用方降级为解析失败）
    func testParseBlock_无数字返回nil() {
        XCTAssertNil(BaiduUsageParser.parse(block: "套餐余量 加载中…", capturedAt: Date()))
    }

    /// 【真实数据】2026-11-11 22:22 独立探针从用户百度千帆后台真实抓到的「余量」区块原文。
    /// 注意真实文案与早前 OCR 猜测的差异：
    ///   - 区块首行是「余量」（不是「套餐余量」）
    ///   - 百分比单独成行「95.06%」（没有「Token Plan」前缀）
    ///   - 「剩余」与数字之间**没有空格**
    func testParseBlock_探针实抓的真实文案() throws {
        let real = """
        余量
        2026-12-11 14:51:08 重置
        限时恢复额度
        95.06%
        剩余665,463,337 / 总量700,000,000 Token
        配置
        专属 API Key
        bce-v3/ALTAK******13df
        """

        let quota = try XCTUnwrap(BaiduUsageParser.parse(block: real, capturedAt: Date()))
        let w = try XCTUnwrap(quota.primaryWindow)

        XCTAssertEqual(w.total, 700_000_000, accuracy: 0.001)
        XCTAssertEqual(w.used, 34_536_663, accuracy: 0.001)      // 700,000,000 − 665,463,337
        XCTAssertEqual(w.usedPercent, 4.9338, accuracy: 0.01)   // 已用 4.93%（页面显示剩余 95.06%）
        XCTAssertEqual(w.displayName, "月")

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: w.resetAt)
        XCTAssertEqual(c.year, 2026)
        XCTAssertEqual(c.month, 12)
        XCTAssertEqual(c.day, 11)
        XCTAssertEqual(c.hour, 14)
        XCTAssertEqual(c.minute, 51)
    }

    /// 千帆月进度条「日均应达」标记（线性均匀消耗下的期望百分比）
    func testExpectedPercent_linearNaturalMonth() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!

        // 续费日 2026-12-11（自然月），周期 = 2026-11-11 14:51:08 → 12-11（整整 30 天）
        let resetAt = try XCTUnwrap(
            cal.date(from: DateComponents(year: 2026, month: 12, day: 11, hour: 14, minute: 51, second: 8)))
        let periodStart = try XCTUnwrap(cal.date(byAdding: .month, value: -1, to: resetAt))

        // 周期起点 = 0%
        XCTAssertEqual(BaiduUsageParser.expectedPercent(resetAt: resetAt, now: periodStart), 0, accuracy: 0.01)
        // 周期中点（11-26，15/30 天）= 50%
        let midpoint = try XCTUnwrap(cal.date(byAdding: .day, value: 15, to: periodStart))
        XCTAssertEqual(BaiduUsageParser.expectedPercent(resetAt: resetAt, now: midpoint), 50, accuracy: 0.01)
        // 周期终点 = 100%
        XCTAssertEqual(BaiduUsageParser.expectedPercent(resetAt: resetAt, now: resetAt), 100, accuracy: 0.01)

        // 越界：晚于续费日 clamp 到 100%
        let after = try XCTUnwrap(cal.date(byAdding: .day, value: 5, to: resetAt))
        XCTAssertEqual(BaiduUsageParser.expectedPercent(resetAt: resetAt, now: after), 100, accuracy: 0.01)
        // 越界：早于周期起点 clamp 到 0%
        let before = try XCTUnwrap(cal.date(byAdding: .day, value: -5, to: periodStart))
        XCTAssertEqual(BaiduUsageParser.expectedPercent(resetAt: resetAt, now: before), 0, accuracy: 0.01)
    }
}