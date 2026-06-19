//
//  DiagnosticsExporterTests.swift
//  QuotaMonitorTests
//
//  验证诊断 JSON 导出 + 脱敏
//

import XCTest
@testable import QuotaMonitor

final class DiagnosticsExporterTests: XCTestCase {
    private func makeConfig() -> DiagConfig {
        DiagConfig(enabled: [.kimi, .minimax, .glm],
                   keyConfigured: [.kimi: true, .minimax: true, .glm: true],
                   warningThreshold: 60, criticalThreshold: 86, dangerThreshold: 95)
    }

    func testExport_okSnapshot_hasStatusAndPercent() throws {
        let snap = ProviderQuota(provider: .kimi,
                                 primaryWindow: QuotaWindow(total: 100, used: 17,
                                                            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                            displayName: "5h"))
        let data = try DiagnosticsExporter.export(
            snapshots: [.kimi: snap], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.8", now: Date(timeIntervalSince1970: 1_700_000_100))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kimi = (json["snapshots"] as? [String: Any])?["kimi"] as? [String: Any]
        XCTAssertEqual(kimi?["status"] as? String, "ok")
        XCTAssertEqual(kimi?["usedPercent"] as? Int, 17)
    }

    func testExport_errorSnapshot_hasErrorAndUnderlying() throws {
        let data = try DiagnosticsExporter.export(
            snapshots: [:],
            errors: [.minimax: .networkUnreachable(.minimax, underlying: "URLError: timedOut")],
            history: [], config: makeConfig(), appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let minimax = (json["snapshots"] as? [String: Any])?["minimax"] as? [String: Any]
        XCTAssertEqual(minimax?["status"] as? String, "error")
        XCTAssertEqual(minimax?["error"] as? String, "networkUnreachable")
        XCTAssertEqual(minimax?["underlying"] as? String, "URLError: timedOut")
    }

    func testExport_glmParsedFields_hasSelectedAndAvailable() throws {
        let raw: [String: Any] = ["data": ["limits": [
            ["type": "TOKENS_LIMIT", "unit": 3, "percentage": 2, "nextResetTime": 1_700_000_000_000],
            ["type": "TOKENS_LIMIT", "unit": 6, "percentage": 32]
        ]]]
        let snap = ProviderQuota(provider: .glm,
                                 primaryWindow: QuotaWindow(total: 100, used: 2,
                                                            resetAt: Date(), displayName: "5h"),
                                 raw: raw)
        let data = try DiagnosticsExporter.export(
            snapshots: [.glm: snap], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let glm = (json["snapshots"] as? [String: Any])?["glm"] as? [String: Any]
        let parsed = try XCTUnwrap(glm?["parsedFields"] as? [String: Any])
        let selected = try XCTUnwrap(parsed["selected"] as? [String: Any])
        XCTAssertEqual(selected["type"] as? String, "TOKENS_LIMIT")
        XCTAssertEqual(selected["unit"] as? Int, 3)
        let available = try XCTUnwrap(parsed["availableLimits"] as? [[String: Any]])
        XCTAssertEqual(available.count, 2)
    }

    func testExport_historyIncluded() throws {
        let entry = DiagEntry(at: Date(), results: [.kimi: .ok(usedPercent: 17)])
        let data = try DiagnosticsExporter.export(
            snapshots: [:], errors: [:], history: [entry],
            config: makeConfig(), appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let history = try XCTUnwrap(json["history"] as? [[String: Any]])
        XCTAssertEqual(history.count, 1)
    }

    /// 脱敏铁律：raw 里混入 Authorization/Key，输出绝不能含
    func testExport_redactsAuthorizationAndKeys() throws {
        let raw: [String: Any] = [
            "data": ["limits": [["type": "TOKENS_LIMIT", "unit": 3, "percentage": 2]]],
            "Authorization": "Bearer sk-secret-key-123456",
            "api_key": "sk-leak-xyz"
        ]
        let snap = ProviderQuota(provider: .glm,
                                 primaryWindow: QuotaWindow(total: 100, used: 2,
                                                            resetAt: Date(), displayName: "5h"),
                                 raw: raw)
        let data = try DiagnosticsExporter.export(
            snapshots: [.glm: snap], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.8", now: Date())
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(jsonString.contains("sk-secret"), "API Key 泄漏到诊断日志")
        XCTAssertFalse(jsonString.contains("sk-leak"), "api_key 泄漏")
        XCTAssertFalse(jsonString.contains("Bearer"), "Authorization 头泄漏")
    }

    func testExport_hasSchemaVersion() throws {
        let data = try DiagnosticsExporter.export(
            snapshots: [:], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, DiagnosticsExporter.schemaVersion)
    }

    // MARK: - v1.0.10 / schema /2：smoothing / fingerprint / lastRefreshAt
    // 动因 BUG-2026-06-19-01：本次靠 usedPercent(13) vs percentage(3) 反差"推断"smoothing 篡改；
    // 升级后诊断 JSON 显式记录 smoothing 决策 + fingerprint，让这类问题从"推断"变"直读"。

    /// 解析 export 结果：顶层 → snapshots → <kind>
    private func snapshotDict(_ data: Data, _ kind: String) throws -> [String: Any] {
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let snapshots = try XCTUnwrap(json["snapshots"] as? [String: Any])
        return try XCTUnwrap(snapshots[kind] as? [String: Any])
    }

    func testExport_smoothingInfo_whenApplied_recordsRawValue() throws {
        // 平滑保留旧值 13、丢弃本次真实值 3 → 诊断须显式记录 applied=true + rawUsedPercent=3
        let snap = ProviderQuota(provider: .glm,
                                 primaryWindow: QuotaWindow(total: 100, used: 13,
                                                            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                            displayName: "5h"),
                                 smoothing: SmoothingInfo(applied: true, rawUsedPercent: 3))
        let data = try DiagnosticsExporter.export(
            snapshots: [.glm: snap], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.10", now: Date(timeIntervalSince1970: 1_700_000_100))
        let glm = try snapshotDict(data, "glm")
        let smoothing = try XCTUnwrap(glm["smoothing"] as? [String: Any])
        XCTAssertEqual(smoothing["applied"] as? Bool, true)
        XCTAssertEqual(smoothing["rawUsedPercent"] as? Double, 3, "rawUsedPercent 应是被丢弃的本次真实值")
    }

    func testExport_smoothingInfo_whenNotApplied_isFalse() throws {
        // 未平滑：smoothing.applied=false，无 rawUsedPercent
        let snap = ProviderQuota(provider: .kimi,
                                 primaryWindow: QuotaWindow(total: 100, used: 17,
                                                            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                            displayName: "5h"))
        let data = try DiagnosticsExporter.export(
            snapshots: [.kimi: snap], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.10", now: Date())
        let kimi = try snapshotDict(data, "kimi")
        let smoothing = try XCTUnwrap(kimi["smoothing"] as? [String: Any])
        XCTAssertEqual(smoothing["applied"] as? Bool, false)
        XCTAssertNil(smoothing["rawUsedPercent"], "未平滑时不应有 rawUsedPercent")
    }

    func testExport_includesFingerprint() throws {
        let reset = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = ProviderQuota(provider: .glm,
                                 primaryWindow: QuotaWindow(total: 100, used: 3, resetAt: reset, displayName: "5h"))
        let data = try DiagnosticsExporter.export(
            snapshots: [.glm: snap], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.10", now: Date())
        let glm = try snapshotDict(data, "glm")
        XCTAssertEqual(glm["fingerprint"] as? String, snap.windowFingerprint,
                       "snapshot 应输出 windowFingerprint 以便诊断指纹类问题")
    }

    func testExport_lastRefreshAt_usesProvidedValue() throws {
        // lastRefreshAt 必须是传入的真实最后刷新时间，而非导出时刻（修复语义 bug）
        let data = try DiagnosticsExporter.export(
            snapshots: [:], errors: [:], history: [],
            config: makeConfig(), appVersion: "1.0.10",
            now: Date(timeIntervalSince1970: 1_700_000_100),
            lastRefreshAt: Date(timeIntervalSince1970: 1_700_000_050))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let lastRefreshAt = try XCTUnwrap(json["lastRefreshAt"] as? String)
        let exportedAt = try XCTUnwrap(json["exportedAt"] as? String)
        XCTAssertNotEqual(lastRefreshAt, exportedAt,
                          "lastRefreshAt 应是真实最后刷新时间，而非导出时刻")
    }
}
