# 诊断日志导出功能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一键导出当前配额状态镜像 + 近期刷新轨迹为脱敏 JSON（剪贴板 + 文件双写），供 AI 快速诊断。

**Architecture:** 3 个新组件（`DiagHistoryStore` ring buffer / `DiagnosticsExporter` 纯函数 / `AppState.exportDiagnostics` IO 集成）+ 1 处增强（`QuotaError.networkUnreachable` 加 `underlying`）。核心逻辑纯函数化可单测，UI/IO 是薄包装。

**Tech Stack:** Swift 5.9+, SwiftUI/AppKit, JSONSerialization, NSPasteboard, FileManager

## Global Constraints

- macOS 13+, Swift 5.9+
- 中文 UI 文案，**严禁 Emoji**
- commit **不加** `Co-Authored-By: Claude` trailer
- **API Key / Authorization 绝不进日志**（脱敏铁律，Task 3 强制测试覆盖）
- 遵循项目陷阱表（`CLAUDE.md`）
- 每个任务结束 `swift test` 必须全过
- 现有测试基线 118；本计划新增后递增

## File Structure

| 文件 | 动作 | 责任 |
|------|------|------|
| `QuotaMonitor/Core/Errors/QuotaError.swift` | 改 | `networkUnreachable` 加 `underlying` |
| `QuotaMonitor/Services/Networking/NetworkingService.swift` | 改 | `fetchOne` catch URLError 时填 underlying |
| `QuotaMonitor/State/DiagHistoryStore.swift` | 新建 | ring buffer 存刷新轨迹 |
| `QuotaMonitor/Services/Diagnostics/DiagnosticsExporter.swift` | 新建 | 纯逻辑：状态 → 脱敏 JSON |
| `QuotaMonitor/State/AppState.swift` | 改 | refresh 写轨迹 + `exportDiagnostics()` IO |
| `QuotaMonitor/UI/MenuBar/MenuBarController.swift` | 改 | 右键菜单加"导出诊断日志" |
| `QuotaMonitor/UI/Popup/PopupView.swift` | 改 | Popup 底部加"诊断"按钮 |
| `QuotaMonitor/Resources/Info.plist` | 改 | 1.0.7 → 1.0.8 |
| `CHANGELOG.md` | 改 | 加 1.0.8 段 |
| `QuotaMonitorTests/QuotaErrorTests.swift` | 改 | 补 underlying 测试 + 更新现有 2 处调用 |
| `QuotaMonitorTests/DiagHistoryStoreTests.swift` | 新建 | ring buffer 测试 |
| `QuotaMonitorTests/DiagnosticsExporterTests.swift` | 新建 | exporter + 脱敏测试 |

---

## Task 1: `QuotaError.networkUnreachable` 增加 `underlying`

**Files:**
- Modify: `QuotaMonitor/Core/Errors/QuotaError.swift`
- Modify: `QuotaMonitor/Services/Networking/NetworkingService.swift`
- Test: `QuotaMonitorTests/QuotaErrorTests.swift`

**Interfaces:**
- Produces: `QuotaError.networkUnreachable(ProviderKind, underlying: String?)` — 后续 Task 3 exporter 读取 `.underlying` 写入 JSON

- [ ] **Step 1: 写失败测试**

追加到 `QuotaErrorTests.swift`：

```swift
func testNetworkUnreachable_errorDescription_includesUnderlying() {
    let err = QuotaError.networkUnreachable(.glm, underlying: "URLError: timedOut")
    XCTAssertEqual(err.errorDescription, "Zhipu GLM 网络不可达（URLError: timedOut）")
}

func testNetworkUnreachable_withoutUnderlying_keepsPlainMessage() {
    let err = QuotaError.networkUnreachable(.kimi, underlying: nil)
    XCTAssertEqual(err.errorDescription, "Kimi Code 网络不可达")
}
```

- [ ] **Step 2: 跑测试看红**

Run: `swift test --filter QuotaErrorTests 2>&1 | tail -10`
Expected: 编译失败 — `networkUnreachable` 缺 `underlying` 参数。

- [ ] **Step 3: 改 `QuotaError`（加 underlying + errorDescription）**

`QuotaError.swift`：

```swift
case networkUnreachable(ProviderKind, underlying: String?)
```

```swift
case .networkUnreachable(let p, let u):
    if let u {
        return "\(p.displayName) 网络不可达（\(u)）"
    }
    return "\(p.displayName) 网络不可达"
```

- [ ] **Step 4: 更新现有调用点**

`NetworkingService.swift` 的 `fetchOne`（v1.0.7 加的 URLError catch）：

```swift
} catch let urlError as URLError {
    logger.error("[\(kind.rawValue, privacy: .public)] transport error -> networkUnreachable")
    return .failure(.networkUnreachable(kind, underlying: "URLError: \(urlError.code.rawValue)"))
}
```

`QuotaErrorTests.swift` 现有 2 处（约 :20、:61）：

```swift
XCTAssertTrue(QuotaError.networkUnreachable(.kimi, underlying: nil).isRetryable)
XCTAssertFalse(QuotaError.networkUnreachable(.kimi, underlying: nil).isUserActionable)
```

- [ ] **Step 5: 跑测试看绿**

Run: `swift test 2>&1 | tail -6`
Expected: 全过（118+，含 2 个新测试）。

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Core/Errors/QuotaError.swift QuotaMonitor/Services/Networking/NetworkingService.swift QuotaMonitorTests/QuotaErrorTests.swift
git commit -m "feat(diag): QuotaError.networkUnreachable 携带 underlying 原因"
```

---

## Task 2: `DiagHistoryStore`（ring buffer）

**Files:**
- Create: `QuotaMonitor/State/DiagHistoryStore.swift`
- Test: `QuotaMonitorTests/DiagHistoryStoreTests.swift`

**Interfaces:**
- Produces: `DiagProviderOutcome`、`DiagEntry`、`DiagHistoryStore` — Task 3 exporter 消费 `[DiagEntry]`，Task 4 AppState 持有 store

- [ ] **Step 1: 写失败测试**

Create `QuotaMonitorTests/DiagHistoryStoreTests.swift`：

```swift
import XCTest
@testable import QuotaMonitor

final class DiagHistoryStoreTests: XCTestCase {
    func testAppend_andRecent_returnsAll() {
        let store = DiagHistoryStore()
        let now = Date()
        store.append(DiagEntry(at: now, results: [.kimi: .ok(usedPercent: 17)]))
        store.append(DiagEntry(at: now, results: [.kimi: .ok(usedPercent: 18)]))

        let recent = store.recent(since: now.addingTimeInterval(-60))
        XCTAssertEqual(recent.count, 2)
    }

    func testCap_dropsOldestBeyond20() {
        let store = DiagHistoryStore()
        let base = Date()
        for i in 0..<25 {
            store.append(DiagEntry(at: base.addingTimeInterval(TimeInterval(i)),
                                   results: [.kimi: .ok(usedPercent: Double(i))]))
        }
        let recent = store.recent(since: base.addingTimeInterval(-1))
        XCTAssertEqual(recent.count, 20, "cap=20，超出应淘汰最旧")
        XCTAssertEqual(recent.first?.results[.kimi], .ok(usedPercent: 5), "最旧保留的是第 6 条")
    }

    func testRecent_filtersByCutoff() {
        let store = DiagHistoryStore()
        let old = Date().addingTimeInterval(-600)   // 10 分钟前
        let recent = Date()
        store.append(DiagEntry(at: old, results: [.glm: .ok(usedPercent: 1)]))
        store.append(DiagEntry(at: recent, results: [.glm: .ok(usedPercent: 2)]))

        let within5min = store.recent(since: recent.addingTimeInterval(-300))
        XCTAssertEqual(within5min.count, 1, "5 分钟外的条目应被过滤")
    }

    func testOutcome_errorCase_carriesType() {
        let outcome = DiagProviderOutcome.error(type: "networkUnreachable")
        XCTAssertEqual(outcome, .error(type: "networkUnreachable"))
    }
}
```

- [ ] **Step 2: 跑测试看红**

Run: `swift test --filter DiagHistoryStoreTests 2>&1 | tail -8`
Expected: 编译失败 — 类型未定义。

- [ ] **Step 3: 实现 `DiagHistoryStore`**

Create `QuotaMonitor/State/DiagHistoryStore.swift`：

```swift
//
//  DiagHistoryStore.swift
//  QuotaMonitor
//
//  诊断轨迹 ring buffer：存最近若干次刷新的精简结果，供"导出诊断日志"附带。
//

import Foundation

/// 单个平台一次刷新的精简结果（诊断用，不含 raw）。
public enum DiagProviderOutcome: Sendable, Equatable {
    case ok(usedPercent: Double)
    case error(type: String)
}

/// 一次刷新的轨迹条目。
public struct DiagEntry: Sendable, Equatable {
    public let at: Date
    public let results: [ProviderKind: DiagProviderOutcome]

    public init(at: Date, results: [ProviderKind: DiagProviderOutcome]) {
        self.at = at
        self.results = results
    }
}

@MainActor
public final class DiagHistoryStore {
    /// 硬上限：最多保留 20 条（导出时再按时间窗过滤）
    public static let cap = 20

    private var entries: [DiagEntry] = []

    public init() {}

    public func append(_ entry: DiagEntry) {
        entries.append(entry)
        if entries.count > Self.cap {
            entries.removeFirst(entries.count - Self.cap)
        }
    }

    /// 取截止时间之后的条目（导出时用 5 分钟窗口调用）
    public func recent(since cutoff: Date) -> [DiagEntry] {
        entries.filter { $0.at >= cutoff }
    }

    /// 测试/调试用
    public var allEntries: [DiagEntry] { entries }
}
```

- [ ] **Step 4: 跑测试看绿**

Run: `swift test --filter DiagHistoryStoreTests 2>&1 | tail -6`
Expected: 4 个测试全过。

- [ ] **Step 5: Commit**

```bash
git add QuotaMonitor/State/DiagHistoryStore.swift QuotaMonitorTests/DiagHistoryStoreTests.swift
git commit -m "feat(diag): DiagHistoryStore ring buffer 存刷新轨迹"
```

---

## Task 3: `DiagnosticsExporter`（纯逻辑 + 脱敏 JSON）

**Files:**
- Create: `QuotaMonitor/Services/Diagnostics/DiagnosticsExporter.swift`
- Test: `QuotaMonitorTests/DiagnosticsExporterTests.swift`

**Interfaces:**
- Consumes: `[ProviderKind: ProviderQuota]`, `[ProviderKind: QuotaError]`, `[DiagEntry]`, `SettingsStore`, `appVersion: String`, `now: Date`
- Produces: `DiagnosticsExporter.export(...) throws -> Data`（JSON）

- [ ] **Step 1: 写失败测试**

Create `QuotaMonitorTests/DiagnosticsExporterTests.swift`：

```swift
import XCTest
@testable import QuotaMonitor

final class DiagnosticsExporterTests: XCTestCase {
    func testExport_okSnapshot_hasStatusAndPercent() throws {
        let snap = ProviderQuota(provider: .kimi,
                                 primaryWindow: QuotaWindow(total: 100, used: 17,
                                                            resetAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                            displayName: "5h"))
        let data = try DiagnosticsExporter.export(
            snapshots: [.kimi: snap], errors: [:], history: [],
            settings: .shared, appVersion: "1.0.8", now: Date(timeIntervalSince1970: 1_700_000_100))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let kimi = try XCTUnwrap(json["snapshots"] as? [String: Any])["kimi"] as? [String: Any]
        XCTAssertEqual(kimi?["status"] as? String, "ok")
        XCTAssertEqual(kimi?["usedPercent"] as? Int, 17)
    }

    func testExport_errorSnapshot_hasErrorAndUnderlying() throws {
        let data = try DiagnosticsExporter.export(
            snapshots: [:],
            errors: [.minimax: .networkUnreachable(.minimax, underlying: "URLError: timedOut")],
            history: [], settings: .shared, appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let minimax = (json["snapshots"] as? [String: Any>)?["minimax"] as? [String: Any]
        XCTAssertEqual(minimax?["status"] as? String, "error")
        XCTAssertEqual(minimax?["error"] as? String, "networkUnreachable")
        XCTAssertEqual(minimax?["underlying"] as? String, "URLError: timedOut")
    }

    func testExport_glmParsedFields_hasSelectedAndAvailable() throws {
        // GLM raw 含 2 个 limit，selected 应是 TOKENS_LIMIT+unit=3
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
            settings: .shared, appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let glm = (json["snapshots"] as? [String: Any>)?["glm"] as? [String: Any]
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
            settings: .shared, appVersion: "1.0.8", now: Date())
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
            settings: .shared, appVersion: "1.0.8", now: Date())
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertFalse(jsonString.contains("sk-secret"), "API Key 泄漏到诊断日志")
        XCTAssertFalse(jsonString.contains("sk-leak"), "api_key 泄漏")
        XCTAssertFalse(jsonString.contains("Bearer"), "Authorization 头泄漏")
    }

    func testExport_hasSchemaVersion() throws {
        let data = try DiagnosticsExporter.export(
            snapshots: [:], errors: [:], history: [],
            settings: .shared, appVersion: "1.0.8", now: Date())
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema"] as? String, DiagnosticsExporter.schemaVersion)
    }
}
```

- [ ] **Step 2: 跑测试看红**

Run: `swift test --filter DiagnosticsExporterTests 2>&1 | tail -8`
Expected: 编译失败 — `DiagnosticsExporter` 未定义。

- [ ] **Step 3: 实现 `DiagnosticsExporter`**

Create `QuotaMonitor/Services/Diagnostics/DiagnosticsExporter.swift`：

```swift
//
//  DiagnosticsExporter.swift
//  QuotaMonitor
//
//  纯逻辑：把当前快照 + 轨迹导出为脱敏 JSON，供 AI 诊断。
//  不含 API Key / Authorization（脱敏铁律）。
//

import Foundation

public enum DiagnosticsExporter {
    public static let schemaVersion = "QuotaMonitor-diag/1"

    /// 敏感字符串模式：序列化后从所有字符串值中清除
    private static let sensitivePatterns: [String] = [
        #"(?i)authorization"#,         // Authorization 头
        #"(?i)bearer\s+[\w\.\-]+"#,    // Bearer xxx
        #"sk-[\w\-]{8,}"#,             // sk- 开头的 Key
        #"(?i)api[_-]?key"#            // api_key 字段名
    ]

    public static func export(
        snapshots: [ProviderKind: ProviderQuota],
        errors: [ProviderKind: QuotaError],
        history: [DiagEntry],
        settings: SettingsStore,
        appVersion: String,
        now: Date
    ) throws -> Data {
        var root: [String: Any] = [
            "schema": schemaVersion,
            "exportedAt": iso(now),
            "appVersion": appVersion,
            "lastRefreshAt": iso(now),  // 调用方可覆盖
            "config": configDict(settings),
            "snapshots": snapshotsDict(snapshots: snapshots, errors: errors),
            "history": history.map(historyEntryDict)
        ]
        sanitize(&root)

        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Helpers

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withTimeZone]
        return f.string(from: d)
    }

    private static func configDict(_ s: SettingsStore) -> [String: Any] {
        // keyConfigured 不含 Key 本身，只布尔（SettingsStore.keyState 返回 KeyState 枚举）
        var keyConfigured: [String: Bool] = [:]
        for k in ProviderKind.allCases {
            keyConfigured[k.rawValue] = (s.keyState(for: k) == .configured)
        }
        return [
            "enabled": s.enabledKinds().map { $0.rawValue },
            "keyConfigured": keyConfigured,
            "thresholds": [
                "warning": s.warningThreshold,
                "critical": s.criticalThreshold,
                "danger": s.dangerThreshold
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
                out[kind.rawValue] = errorDict(kind, err)
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

    private static func errorDict(_ kind: ProviderKind, _ err: QuotaError) -> [String: Any] {
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
            let available = limits.compactMap { limit -> [String: Any]? in
                guard let t = limit["type"], let u = limit["unit"] else { return nil }
                return ["type": t, "unit": u, "percentage": limit["percentage"] ?? 0]
            }
            // selected = TOKENS_LIMIT + unit=3（与 GLMProvider 一致）
            let selected = available.first {
                ($0["type"] as? String) == "TOKENS_LIMIT" && ($0["unit"] as? Int) == 3
            } ?? available.first
            return ["selected": selected ?? NSNull(), "availableLimits": available]
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
            return ["detail.used": detail["used"] ?? NSNull(),
                    "detail.limit": detail["limit"] ?? NSNull()]
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

    /// 递归脱敏：对所有 String 值套用敏感正则（替换为 [REDACTED]）
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
            for k in dict.keys { sanitize(&dict[k]) }
            obj = dict
        } else if var arr = obj as? [Any] {
            for i in arr.indices { sanitize(&arr[i]) }
            obj = arr
        }
    }
}
```

> **已核对 API：** `SettingsStore.keyState(for:)` 返回 `KeyState` 枚举，`.configured` 表示已配置（见 `SettingsStore.swift:114`、`:191`）。`enabledKinds()` 在 `:183`。

- [ ] **Step 4: 跑测试看绿**

Run: `swift test --filter DiagnosticsExporterTests 2>&1 | tail -8`
Expected: 6 个测试全过（含脱敏测试）。

- [ ] **Step 5: 跑全套确认无回归**

Run: `swift test 2>&1 | tail -6`
Expected: 全过。

- [ ] **Step 6: Commit**

```bash
git add QuotaMonitor/Services/Diagnostics/DiagnosticsExporter.swift QuotaMonitorTests/DiagnosticsExporterTests.swift
git commit -m "feat(diag): DiagnosticsExporter 纯逻辑导出脱敏 JSON"
```

---

## Task 4: `AppState` 集成（写轨迹 + 导出 IO）

**Files:**
- Modify: `QuotaMonitor/State/AppState.swift`
- Modify: `QuotaMonitor/State/QuotaStore.swift`（如需暴露 errors 给 exporter 之外，已暴露）

**Interfaces:**
- Consumes: `DiagHistoryStore`（Task 2）、`DiagnosticsExporter`（Task 3）
- Produces: `AppState.exportDiagnostics() -> DiagExportResult`（含文件路径），供 Task 5 入口调用

- [ ] **Step 1: 在 `AppState` 加 history store 属性 + refresh 末尾写轨迹**

`AppState.swift`：

```swift
public let diagHistory = DiagHistoryStore()
```

在 `refresh()` 末尾（`store.update(...)` 之后、告警之前或之后均可）：

```swift
// 写诊断轨迹（精简：每平台 ok(pct) / err(type)）
var outcomes: [ProviderKind: DiagProviderOutcome] = [:]
for kind in target {
    if let q = newSnapshots[kind], let pct = q.primaryUsedPercent {
        outcomes[kind] = .ok(usedPercent: pct)
    } else if let err = newErrors[kind] {
        outcomes[kind] = .error(type: diagErrorType(err))
    }
}
diagHistory.append(DiagEntry(at: Date(), results: outcomes))
```

加辅助：

```swift
private func diagErrorType(_ err: QuotaError) -> String {
    switch err {
    case .networkUnreachable: return "networkUnreachable"
    case .keyMissing: return "keyMissing"
    case .keyInvalid: return "keyInvalid"
    case .rateLimited: return "rateLimited"
    case .serverError: return "serverError"
    case .decodingFailed: return "decodingFailed"
    case .unknown: return "unknown"
    case .mockDisabled: return "mockDisabled"
    case .cancelled: return "cancelled"
    }
}
```

> 注：`diagErrorType` 与 exporter 的 `errorType` 字符串映射重复。可选重构：把映射提到 `QuotaError` 的 `var diagType: String`。本任务先内联，避免跨任务耦合。

- [ ] **Step 2: 加 `exportDiagnostics()`（文件 + 剪贴板）**

```swift
public struct DiagExportResult: Sendable {
    public let url: URL?
    public let copiedToPasteboard: Bool
    public let error: String?
}

public func exportDiagnostics() -> DiagExportResult {
    let now = Date()
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    do {
        let data = try DiagnosticsExporter.export(
            snapshots: store.snapshots,
            errors: store.errors,
            history: diagHistory.recent(since: now.addingTimeInterval(-300)),  // 最近 5 分钟
            settings: settings,
            appVersion: version,
            now: now)

        // 写文件
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("QuotaMonitor-diag-\(df.string(from: now)).json")
        try data.write(to: url, options: .atomic)

        // 写剪贴板
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(String(data: data, encoding: .utf8) ?? "", forType: .string)

        return DiagExportResult(url: url, copiedToPasteboard: true, error: nil)
    } catch {
        logger.error("export diagnostics failed: \(error.localizedDescription, privacy: .public)")
        return DiagExportResult(url: nil, copiedToPasteboard: false, error: error.localizedDescription)
    }
}
```

AppState 顶部 `import AppKit`（用 NSPasteboard）。

- [ ] **Step 3: 编译 + 手动验证**

Run: `swift build -c release 2>&1 | tail -5`
Expected: Build complete。

> 这一步是 IO 集成（文件/剪贴板），不做单测——核心逻辑（exporter）已在 Task 3 覆盖。运行时验证在 Task 5 接好入口后整体手测。

- [ ] **Step 4: Commit**

```bash
git add QuotaMonitor/State/AppState.swift
git commit -m "feat(diag): AppState 写诊断轨迹 + exportDiagnostics 文件/剪贴板双写"
```

---

## Task 5: UI 入口（右键菜单 + Popup 按钮）

**Files:**
- Modify: `QuotaMonitor/UI/MenuBar/MenuBarController.swift`
- Modify: `QuotaMonitor/UI/Popup/PopupView.swift`

- [ ] **Step 1: 右键菜单加项**

`MenuBarController.swift` 的 `showContextMenu()`：

```swift
menu.addItem(withTitle: "手动刷新", action: #selector(menuRefresh), keyEquivalent: "r")
menu.addItem(withTitle: "设置...", action: #selector(menuOpenSettings), keyEquivalent: ",")
menu.addItem(withTitle: "导出诊断日志", action: #selector(menuExportDiag), keyEquivalent: "d")
menu.addItem(.separator())
menu.addItem(withTitle: "退出", action: #selector(menuQuit), keyEquivalent: "q")
```

加 action：

```swift
@objc private func menuExportDiag() {
    let result = appState.exportDiagnostics()
    if let url = result.url {
        // 短暂提示（状态栏 title 闪一下 或 NSUserNotification/无）
        statusItem.button?.toolTip = "已导出：\(url.path)"
    }
}
```

- [ ] **Step 2: Popup 底部加"诊断"按钮**

`PopupView.swift` 底部 `HStack`（"设置 / 刷新于 / v版本 / 退出"）插入：

```swift
Button("诊断") {
    _ = appState.exportDiagnostics()
}
.buttonStyle(.plain)
.font(Typography.caption)
.foregroundColor(SemanticColors.secondary)
.help("导出当前诊断日志到下载文件夹并复制到剪贴板")
```

- [ ] **Step 3: 编译验证**

Run: `swift build -c release 2>&1 | tail -5`
Expected: Build complete。

- [ ] **Step 4: 打包本地手测**

```bash
cp .build/release/QuotaMonitor build/QuotaMonitor.app/Contents/MacOS/QuotaMonitor
cp QuotaMonitor/Resources/Info.plist build/QuotaMonitor.app/Contents/Info.plist
codesign --force --deep --sign - build/QuotaMonitor.app
osascript -e 'tell application "QuotaMonitor" to quit' 2>/dev/null; pkill -x QuotaMonitor 2>/dev/null
rm -rf /Applications/QuotaMonitor.app
cp -R build/QuotaMonitor.app /Applications/QuotaMonitor.app
open /Applications/QuotaMonitor.app
```

手测：
- 状态栏右键 → 出现"导出诊断日志" → 点击 → `~/Downloads/` 出现 `QuotaMonitor-diag-*.json`
- 打开 JSON 确认：含 schema/snapshots/history；**无 Authorization/Key**
- ⌘V 粘贴到文本框 → 是同一份 JSON

- [ ] **Step 5: Commit**

```bash
git add QuotaMonitor/UI/MenuBar/MenuBarController.swift QuotaMonitor/UI/Popup/PopupView.swift
git commit -m "feat(diag): 右键菜单与 Popup 加导出诊断日志入口"
```

---

## Task 6: 收尾发版（bump + CHANGELOG + 4 步落地）

**Files:**
- Modify: `QuotaMonitor/Resources/Info.plist`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: bump 版本**

`Info.plist`：`CFBundleShortVersionString` 1.0.7 → **1.0.8**；`CFBundleVersion` +1。

- [ ] **Step 2: CHANGELOG 加 1.0.8 段**

在 `## [1.0.7]` 之前插入：

```markdown
## [1.0.8] - 2026-06-18

**新功能：诊断日志导出** — 一键"拍照式"导出当前配额状态镜像 + 近期刷新轨迹为脱敏 JSON（剪贴板 + 文件双写），供 AI 快速诊断。详见 `docs/superpowers/specs/2026-06-18-diagnostics-export-design.md`。

### 新增
- 右键菜单 / Popup 加"导出诊断日志"：写 `~/Downloads/QuotaMonitor-diag-<ts>.json` + 复制到剪贴板
- `DiagHistoryStore`：ring buffer 存最近 20 条刷新轨迹，导出时按 5 分钟窗口过滤
- `DiagnosticsExporter`：纯逻辑导出脱敏 JSON（各平台提炼关键字段，非 raw dump；正则清除 Authorization/Bearer/Key）
- `QuotaError.networkUnreachable` 加 `underlying`，错误信息能说清"为什么不可达"（落地 incident report A-2）

### 测试
- 新增 `DiagnosticsExporterTests`（6）、`DiagHistoryStoreTests`（4）；补 `QuotaErrorTests` underlying
- `swift test` 全过
```

- [ ] **Step 3: Commit + 4 步落地**

```bash
swift test 2>&1 | tail -6                    # 确认全过
git add -A && git commit -m "chore(release): 准备 1.0.8"
```

4 步落地（对外动作，按 `docs/SOP-bug-fix.md` 二次确认后执行）：
- 替换 `/Applications`（已在 Task 5 Step 4 做过本地手测版本）
- `./scripts/release.sh 1.0.8` 推 GitHub 发版

---

## Self-Review（已执行）

- **Spec 覆盖**：§2 需求（范围/输出/格式/内容/入口/隐私）→ Task 1-5 全覆盖；§3 架构 4 组件 → Task 1/2/3/4；§4 JSON schema → Task 3 实现 + 测试；§5 脱敏 → Task 3 脱敏测试；§6 测试计划 → Task 1/2/3；§7 入口 → Task 5。无遗漏。
- **Placeholder**：无。`SettingsStore.keyState(for:) == .configured` 已核对真实 API（`:114`/`:191`）。
- **类型一致**：`DiagProviderOutcome` / `DiagEntry` / `DiagHistoryStore.recent(since:)` / `DiagnosticsExporter.export(...)` / `AppState.exportDiagnostics()` / `DiagExportResult` 在 Task 2/3/4/5 引用名一致。`networkUnreachable(_, underlying:)` 在 Task 1/3 一致。
