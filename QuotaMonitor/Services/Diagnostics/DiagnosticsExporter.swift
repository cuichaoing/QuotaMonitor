//
//  DiagnosticsExporter.swift
//  QuotaMonitor
//
//  纯逻辑：把当前快照 + 轨迹导出为脱敏 JSON，供 AI 诊断。
//  纯函数 nonisolated，可单测。不含 API Key / Authorization（脱敏铁律）。
//

import Foundation

/// 导出诊断快照所需的配置（值类型快照，从 SettingsStore 构造）。
/// 用值类型而非 SettingsStore，避免 exporter 依赖 @MainActor（保持纯函数可测）。
public struct DiagConfig: Sendable, Equatable {
    public let enabled: [ProviderKind]
    public let keyConfigured: [ProviderKind: Bool]
    public let warningThreshold: Double
    public let criticalThreshold: Double
    public let dangerThreshold: Double

    public init(enabled: [ProviderKind], keyConfigured: [ProviderKind: Bool],
                warningThreshold: Double, criticalThreshold: Double, dangerThreshold: Double) {
        self.enabled = enabled
        self.keyConfigured = keyConfigured
        self.warningThreshold = warningThreshold
        self.criticalThreshold = criticalThreshold
        self.dangerThreshold = dangerThreshold
    }
}

public enum DiagnosticsExporter {
    public static let schemaVersion = "QuotaMonitor-diag/1"

    /// 敏感字符串模式：序列化后从所有字符串值中清除（defense in depth）
    private static let sensitivePatterns: [String] = [
        #"(?i)authorization"#,
        #"(?i)bearer\s+[\w\.\-]+"#,
        #"sk-[\w\-]{8,}"#,
        #"(?i)api[_-]?key"#
    ]

    public static func export(
        snapshots: [ProviderKind: ProviderQuota],
        errors: [ProviderKind: QuotaError],
        history: [DiagEntry],
        config: DiagConfig,
        appVersion: String,
        now: Date
    ) throws -> Data {
        var rootObject: Any = [
            "schema": schemaVersion,
            "exportedAt": iso(now),
            "appVersion": appVersion,
            "lastRefreshAt": iso(now),
            "config": configDict(config),
            "snapshots": snapshotsDict(snapshots: snapshots, errors: errors),
            "history": history.map(historyEntryDict)
        ]
        sanitize(&rootObject)
        return try JSONSerialization.data(withJSONObject: rootObject, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f.string(from: d)
    }

    private static func configDict(_ c: DiagConfig) -> [String: Any] {
        var keyConfigured: [String: Bool] = [:]
        for (k, v) in c.keyConfigured { keyConfigured[k.rawValue] = v }
        return [
            "enabled": c.enabled.map { $0.rawValue },
            "keyConfigured": keyConfigured,
            "thresholds": [
                "warning": c.warningThreshold,
                "critical": c.criticalThreshold,
                "danger": c.dangerThreshold
            ]
        ]
    }

    private static func snapshotsDict(
        snapshots: [ProviderKind: ProviderQuota],
        errors: [ProviderKind: QuotaError]
    ) -> [String: Any] {
        var out: [String: Any] = [:]
        for kind in ProviderKind.allCases {
            if let err = errors[kind] {
                out[kind.rawValue] = errorDict(err)
            } else if let snap = snapshots[kind] {
                out[kind.rawValue] = okDict(kind, snap)
            } else {
                out[kind.rawValue] = ["status": "unconfigured"]
            }
        }
        return out
    }

    private static func okDict(_ kind: ProviderKind, _ snap: ProviderQuota) -> [String: Any] {
        var d: [String: Any] = ["status": "ok"]
        if let w = snap.primaryWindow {
            d["usedPercent"] = snap.displayPercent ?? 0
            d["resetAt"] = iso(w.resetAt)
            d["window"] = w.displayName
        }
        if let parsed = parsedFields(for: kind, raw: snap.raw) {
            d["parsedFields"] = parsed
        }
        return d
    }

    private static func errorDict(_ err: QuotaError) -> [String: Any] {
        var d: [String: Any] = ["status": "error", "error": errorType(err)]
        if case .networkUnreachable(_, let u?) = err { d["underlying"] = u }
        return d
    }

    private static func errorType(_ err: QuotaError) -> String {
        switch err {
        case .keyMissing: return "keyMissing"
        case .keyInvalid: return "keyInvalid"
        case .rateLimited: return "rateLimited"
        case .serverError: return "serverError"
        case .decodingFailed: return "decodingFailed"
        case .networkUnreachable: return "networkUnreachable"
        case .mockDisabled: return "mockDisabled"
        case .cancelled: return "cancelled"
        case .unknown: return "unknown"
        }
    }

    /// 按 kind 从 raw 提炼诊断关键字段（不 dump 完整 raw）
    private static func parsedFields(for kind: ProviderKind, raw: [String: Any]?) -> [String: Any]? {
        guard let raw else { return nil }
        switch kind {
        case .glm:
            guard let data = raw["data"] as? [String: Any],
                  let limits = data["limits"] as? [[String: Any]] else { return nil }
            let available: [[String: Any]] = limits.compactMap { limit in
                guard limit["type"] != nil, limit["unit"] != nil else { return nil }
                return [
                    "type": limit["type"] as Any,
                    "unit": limit["unit"] as Any,
                    "percentage": limit["percentage"] ?? 0
                ]
            }
            let selected = available.first {
                ($0["type"] as? String) == "TOKENS_LIMIT" && ($0["unit"] as? Int) == 3
            } ?? available.first
            return [
                "selected": selected ?? NSNull(),
                "availableLimits": available
            ]
        case .minimax:
            guard let remains = raw["model_remains"] as? [[String: Any]] else { return nil }
            let general = remains.first { ($0["model_name"] as? String) == "general" } ?? remains.first
            return [
                "selectedModel": general?["model_name"] ?? NSNull(),
                "current_interval_remaining_percent": general?["current_interval_remaining_percent"] ?? NSNull()
            ]
        case .kimi:
            guard let limits = raw["limits"] as? [[String: Any]],
                  let detail = limits.first?["detail"] as? [String: Any] else { return nil }
            return [
                "detail.used": detail["used"] ?? NSNull(),
                "detail.limit": detail["limit"] ?? NSNull()
            ]
        }
    }

    private static func historyEntryDict(_ e: DiagEntry) -> [String: Any] {
        var d: [String: Any] = ["at": iso(e.at)]
        for (kind, outcome) in e.results {
            switch outcome {
            case .ok(let pct): d[kind.rawValue] = ["ok": true, "pct": pct]
            case .error(let t): d[kind.rawValue] = ["ok": false, "err": t]
            }
        }
        return d
    }

    /// 递归脱敏：对所有 String 值套用敏感正则（命中则替换为 [REDACTED]）。
    /// defense in depth——当前 exporter 只写提炼字段，正常不会命中；保留作安全网。
    private static func sanitize(_ obj: inout Any) {
        if var s = obj as? String {
            for pattern in sensitivePatterns {
                if let re = try? NSRegularExpression(pattern: pattern),
                   re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil {
                    s = "[REDACTED]"
                    break
                }
            }
            obj = s
        } else if var dict = obj as? [String: Any] {
            for k in Array(dict.keys) {
                var v: Any = dict[k]!
                sanitize(&v)
                dict[k] = v
            }
            obj = dict
        } else if var arr = obj as? [Any] {
            for i in arr.indices {
                var v: Any = arr[i]
                sanitize(&v)
                arr[i] = v
            }
            obj = arr
        }
    }
}
