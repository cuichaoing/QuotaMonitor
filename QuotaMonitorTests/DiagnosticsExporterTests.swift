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
}
