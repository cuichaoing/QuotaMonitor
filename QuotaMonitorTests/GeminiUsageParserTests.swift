//
//  GeminiUsageParserTests.swift
//  QuotaMonitorTests
//
//  解析器测试：夹具取自 2026-10-29 真实登录态 DOM 快照（scripts/gemini_login_probe.swift 落盘），
//  含 Google 原始 utility class，确保对生产 DOM 结构真实有效。
//

import XCTest
@testable import QuotaMonitor

final class GeminiUsageParserTests: XCTestCase {

    // MARK: - 真实 DOM 夹具（gemini.google.com/usage, 2026-10-29）

    static let currentUsageBlock = """
        <li data-testid="current-usage" class="x9f619 xeuugli x3ct3a4 x1xvrxu7 x1gbzdpk x5agskx xng3xce xc342km xh2tq4o x1a2a7pz xw7rl1t x1vu5tfk xqu58b0 x10ie4so x1uqcyo5 xxinxu1 x5wr7oq xqa98kd"><div class="x9f619 xeuugli xng3xce xc342km x1a2a7pz x78zum5 xdt5ytf"><div class="x9f619 xeuugli xng3xce xc342km x1a2a7pz x78zum5 x1q0g3np x6s0dn4 x1qughib x11fuqc3"><div class="x9f619 xeuugli xng3xce xc342km x1a2a7pz x78zum5 x1q0g3np x6s0dn4 x2ibuj"><strong class="x1ghz6dp x1717udv x17kjdy0 xb13rfl x13qsv9v xxc43yo x19d36u7 xkbjdg9 x184j2wm x1o2sk6j">当前用量</strong><button aria-label="有关用量限额的信息" type="button" tabindex="0" data-base-ui-click-trigger="" id="_r_1_" aria-haspopup="dialog" aria-expanded="false" class="x9f619 xeuugli x1n2onr6 x16tdsg8 x47umbl x5lhr3w x16ye13r x1a2a7pz x1jcvrdo x1pqdn1g x1jhgk4a x1hl8ikr xln7xf2 x1hl2dhg xjyslct xc8icb0 xjbqb8w x9r1u3d xng3xce xc342km x1ypdohk xarstr8 x1k48kgn x17e5bxp xtnhwn2 x1s928wv xmf22ne x2q1x1w x1j6awrg x1ghz6dp x1717udv x17kjdy0 xb13rfl x11d78qn xxc43yo x1jvydc1 xco3t2n xo1l8bm x1fc57z9 xs4toe8" style="--x-width: 20px; --x-height: 20px;"><span aria-hidden="true" class="xlh3980 xvmahel xb3r6kr x6s0dn4 x1heor9g x3nfvp2 x2lah0s x1y5z1qm x1j61x8r xl56j7k x1i21sxh xo5v014 x47corl x6mezaz x87ps6o xuxw1ft xp5j34i x1djzii9 xwsyq91 x1qx5ct2 xw4jnvo" style="font-variation-settings: &quot;FILL&quot; 0, &quot;GRAD&quot; 0, &quot;ROND&quot; 100, &quot;opsz&quot; 20, &quot;wght&quot; 320;">info</span></button></div><strong class="x1ghz6dp x1717udv x17kjdy0 xb13rfl x13qsv9v xxc43yo x1jvydc1 xkbjdg9 x184j2wm x1fc57z9">已使用 31%</strong></div><div class="x9f619 xeuugli xng3xce xc342km xu54n6k x1qfedo xh8yej3 x1a2a7pz"><div aria-hidden="true" class="x9f619 xeuugli x1xvrxu7 xlro2ad x5agskx x47umbl xb3r6kr xh8yej3 x16ye13r x1a2a7pz xlo2gbs xew9wwv x1oyx53q" style="--x-height: 12px;"><span class="x9f619 xeuugli x1lliihq x47umbl x5lhr3w x5yr21d x1a2a7pz x19ymgil xew9wwv x1oyx53q xqckqws x2r3uzy x14jqsep" style="--x-width: 31%;"></span></div></div><span class="x1ghz6dp x1717udv x17kjdy0 xb13rfl x13qsv9v xxc43yo x1jvydc1 xkbjdg9 x184j2wm x1fc57z9 xs4toe8">重置时间：13:01</span></div></li>
    """

    static let weeklyUsageBlock = """
        <li data-testid="weekly-usage" class="x9f619 xeuugli x3ct3a4 x1xvrxu7 x1gbzdpk x5agskx xng3xce xc342km xh2tq4o x1a2a7pz xw7rl1t x1vu5tfk xqu58b0 x10ie4so x1uqcyo5 xxinxu1 x5wr7oq xqa98kd"><div class="x9f619 xeuugli xng3xce xc342km x1a2a7pz x78zum5 x1q0g3np x6s0dn4 x1qughib x11fuqc3"><span class="x9f619 xeuugli xng3xce xc342km x1a2a7pz x78zum5 xdt5ytf"><strong class="x1ghz6dp x1717udv x17kjdy0 xb13rfl x13qsv9v xxc43yo x1jvydc1 xkbjdg9 x184j2wm x1fc57z9">每周限额</strong><span class="x1ghz6dp x1717udv x17kjdy0 xb13rfl x82e0zp xxc43yo x4z9k3i x14fp2pg xfbjfs5 xuy8w9f xs4toe8">重置时间：11月2日16:01</span></span><strong class="x1ghz6dp x1717udv x17kjdy0 xb13rfl x13qsv9v xxc43yo x1jvydc1 xkbjdg9 x184j2wm x1fc57z9">已使用 3%</strong></div></li>
    """

    func testParse_realDOM_extractsBothWindows() {
        let page = GeminiUsageParser.parse(html: Self.currentUsageBlock + Self.weeklyUsageBlock)
        XCTAssertEqual(page.currentUsedPercent, 31)
        XCTAssertEqual(page.currentResetText, "13:01")
        XCTAssertEqual(page.weeklyUsedPercent, 3)
        XCTAssertEqual(page.weeklyResetText, "11月2日16:01")
        XCTAssertTrue(page.hasAnyValue)
    }

    func testParse_realDOM_currentBlockOnly() {
        let page = GeminiUsageParser.parse(html: Self.currentUsageBlock)
        XCTAssertEqual(page.currentUsedPercent, 31)
        XCTAssertNil(page.weeklyUsedPercent)
        XCTAssertFalse(page.hasAnyValue == false)
    }

    func testParse_emptyHTML_allNil() {
        let page = GeminiUsageParser.parse(html: "<html><body>未登录</body></html>")
        XCTAssertNil(page.currentUsedPercent)
        XCTAssertNil(page.weeklyUsedPercent)
        XCTAssertNil(page.currentResetText)
        XCTAssertNil(page.weeklyResetText)
        XCTAssertFalse(page.hasAnyValue)
    }

    /// 兜底链：无「已使用」文本时回退进度条内联样式（语言无关，英文 UI 场景）
    func testParse_fallbackProgressWidth_withoutLocalizedText() {
        let html = """
                <li data-testid="current-usage"><div><strong>Current usage</strong></div>
                <span style="--x-width: 42%;"></span></li>
        """
        let page = GeminiUsageParser.parse(html: html)
        XCTAssertEqual(page.currentUsedPercent, 42)
    }

    /// 英文 UI 变体（Used 31%）
    func testParse_englishUI_usedText() {
        let html = """
                <li data-testid="current-usage"><strong>Current usage</strong>
                <strong>Used 31%</strong><span>Resets at 1:01 PM</span></li>
        """
        let page = GeminiUsageParser.parse(html: html)
        XCTAssertEqual(page.currentUsedPercent, 31)
    }

    // MARK: - 重置时间解析

    private let tz = TimeZone(identifier: "Asia/Shanghai")!

    private func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func testResetTime_timeOnly_futureToday() {
        let now = date(2026, 10, 29, 9, 0)
        let parsed = GeminiUsageParser.parseResetTime("13:01", now: now, timeZone: tz)
        XCTAssertEqual(parsed, date(2026, 10, 29, 13, 1))
    }

    func testResetTime_timeOnly_alreadyPast_rollsToTomorrow() {
        let now = date(2026, 10, 29, 14, 0)
        let parsed = GeminiUsageParser.parseResetTime("13:01", now: now, timeZone: tz)
        XCTAssertEqual(parsed, date(2026, 10, 30, 13, 1))
    }

    func testResetTime_monthDay_withinThisYear() {
        let now = date(2026, 10, 29, 12, 0)
        let parsed = GeminiUsageParser.parseResetTime("11月2日16:01", now: now, timeZone: tz)
        XCTAssertEqual(parsed, date(2026, 11, 2, 16, 1))
    }

    func testResetTime_monthDay_yearRollover() {
        let now = date(2026, 12, 30, 12, 0)
        let parsed = GeminiUsageParser.parseResetTime("1月2日16:01", now: now, timeZone: tz)
        XCTAssertEqual(parsed, date(2027, 1, 2, 16, 1))
    }

    func testResetTime_monthDay_withSpace() {
        let now = date(2026, 10, 29, 12, 0)
        let parsed = GeminiUsageParser.parseResetTime("11月2日 16:01", now: now, timeZone: tz)
        XCTAssertEqual(parsed, date(2026, 11, 2, 16, 1))
    }

    func testResetTime_garbage_returnsNil() {
        XCTAssertNil(GeminiUsageParser.parseResetTime("稍后重置", now: Date(), timeZone: tz))
        XCTAssertNil(GeminiUsageParser.parseResetTime("", now: Date(), timeZone: tz))
    }
}
