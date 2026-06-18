# 诊断日志导出功能 · 设计文档（Spec）

> 日期：2026-06-18
> 状态：设计已认可，待写实现计划
> 关联：BUG-2026-06-18-01（根因 C 取证需求）、`docs/incident-reports/2026-06-18-error-misattribution-statusbar-mismatch.md` 第 8 节

---

## 1. 背景与目标

用户报告 bug 时，难以精确描述 UI 上的混乱状态（典型案例：v1.0.7 的"MiniMax/GLM 显示 Kimi Code 网络不可达"、状态栏 `G=33` 与 Popup 离线不一致）。这类问题往往涉及"某一刻各平台到底成功还是失败、值是多少、何时开始失败"，缺乏运行时证据时只能靠静态分析猜。

本功能提供一键**"拍照式"诊断导出**：点一下，抓取点击那一刻的精炼状态镜像 + 最近一小段轨迹，打包成轻量 JSON 文件，配用户的描述一起喂给 AI 快速诊断。

### 核心原则（用户原话凝练）

- **拍照式**：抓点击那一刻的状态镜像
- **不是巨大 raw 文件**，而是**相关信息**（提炼关键字段）
- **附带前几秒/几分钟的轨迹**（状态转变过程）
- **轻量打包文件**

---

## 2. 需求决策（已与用户确认）

| 维度 | 决策 |
|------|------|
| 范围 | 当前快照 + 近期轨迹（ring buffer） |
| 输出 | 剪贴板 + 文件双写 `~/Downloads/QuotaMonitor-diag-<ts>.json` |
| 格式 | JSON（结构化、AI 解析零歧义、轻量） |
| 内容 | 精炼关键字段（非 raw dump）+ 近期轨迹 |
| 入口 | 右键菜单 + Popup 底部按钮，两者都调 `appState.exportDiagnostics()` |
| 隐私 | API Key / Authorization **绝不**进日志；Key 只记"已配置/未配置" |

---

## 3. 架构

### 3.1 组件（3 新 + 1 改）

| 组件 | 角色 | 可测性 |
|------|------|--------|
| `DiagHistoryStore`（新） | `@MainActor` ring buffer，存最近刷新轨迹。cap = 20 条硬上限；导出时再按 5 分钟时间窗过滤 | 纯数据，可单测 append / cap 淘汰 / 时间窗过滤 |
| `DiagnosticsExporter`（新） | 纯逻辑：`export(snapshots, errors, history, settings, version, now) -> Data`（JSON） | 纯函数，重点单测（含脱敏） |
| `QuotaError.networkUnreachable`（改） | 加 `underlying: String?`，携带 `URLError.code`（如 `timedOut`） | 顺带落地 incident report A-2（networkUnreachable 应能说清"为什么不可达"） |
| `AppState.exportDiagnostics()` | 调 exporter 生成 JSON → 写文件 + `NSPasteboard` | 委托 exporter，薄包装 |

**提炼关键字段（parsedFields）放 `DiagnosticsExporter` 内 `switch kind`**，不改 `Provider` 协议、不动各 Provider。exporter 按 `ProviderKind` 从 `ProviderQuota.raw` 提炼诊断关键字段：

| 平台 | 提炼字段 |
|------|----------|
| GLM | `selected{type,unit,percentage}` + `availableLimits[]{type,unit,percentage}`（让 AI 判断是否选错窗口） |
| MiniMax | `selectedModel` + `current_interval_remaining_percent` |
| Kimi | `detail.used` / `detail.limit` |

这些是"相关信息"，**不 dump 完整 raw**。

### 3.2 数据流

```
每轮 refresh（AppState.refresh）：
  fetchAll → snapshots / errors 写 QuotaStore
           → DiagHistoryStore.append(DiagEntry)         ← 新增一行
              DiagEntry = { at: Date, perProvider: [kind: ok(pct) | err(typeString)] }

点"导出诊断"（右键 / Popup）：
  AppState.exportDiagnostics()
    → DiagnosticsExporter.export(snapshots, errors, history(≤5min), settings, version, now)
    → JSON Data
    → ① 写 ~/Downloads/QuotaMonitor-diag-<YYYYMMdd-HHmmss>.json
    → ② NSPasteboard 写入同一 JSON 字符串
    → ③ 返回结果（成功/失败 + 路径）给入口，入口弹短暂提示
```

---

## 4. JSON Schema（`schema: "QuotaMonitor-diag/1"`）

```json
{
  "schema": "QuotaMonitor-diag/1",
  "exportedAt": "2026-06-18T20:30:00+0800",
  "appVersion": "1.0.8",
  "lastRefreshAt": "2026-06-18T20:29:55+0800",
  "isRefreshing": false,
  "config": {
    "enabled": ["kimi", "minimax", "glm"],
    "keyConfigured": { "kimi": true, "minimax": true, "glm": true },
    "thresholds": { "warning": 60, "critical": 86, "danger": 95 },
    "refreshIntervals": { "active": 30, "normal": 60, "idle": 300 }
  },
  "snapshots": {
    "kimi": {
      "status": "ok",
      "usedPercent": 17,
      "resetAt": "2026-06-18T22:14:00+0800",
      "window": "5h",
      "parsedFields": { "detail.used": "17", "detail.limit": "100" }
    },
    "minimax": {
      "status": "error",
      "error": "networkUnreachable",
      "underlying": "URLError: timedOut"
    },
    "glm": {
      "status": "ok",
      "usedPercent": 2,
      "resetAt": "2026-06-18T21:48:00+0800",
      "window": "5h",
      "parsedFields": {
        "selected": { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 2 },
        "availableLimits": [
          { "type": "TOKENS_LIMIT", "unit": 3, "percentage": 2 },
          { "type": "TOKENS_LIMIT", "unit": 6, "percentage": 32 }
        ]
      }
    }
  },
  "history": [
    { "at": "2026-06-18T20:29:55+0800",
      "kimi": { "ok": true, "pct": 17 },
      "minimax": { "ok": false, "err": "networkUnreachable" },
      "glm": { "ok": true, "pct": 2 } },
    { "at": "2026-06-18T20:29:25+0800",
      "kimi": { "ok": true, "pct": 16 },
      "minimax": { "ok": true, "pct": 45 },
      "glm": { "ok": true, "pct": 2 } }
  ]
}
```

**字段说明**：
- `status`: `ok` | `error` | `unconfigured`（无 Key）
- 成功节点含 `usedPercent` / `resetAt` / `window` / `parsedFields`
- 失败节点含 `error`（类型名）+ `underlying`（底层原因，可空）
- `history` 每条精简：时间 + 各平台 `ok+pct` 或 `err`
- 时间一律 ISO8601 带时区

---

## 5. 脱敏（铁律，不可违反）

序列化前对任何字符串值做正则清除：
- 匹配并移除 `Authorization` / `Bearer ...` / `sk-` / 形似 API Key 的长 token
- `parsedFields` 只写提炼字段名 + 值，**不写完整 raw**
- Key 状态只通过 `config.keyConfigured` 的布尔表达，**不写 Key 本身**

测试强制覆盖：构造含 `"Authorization":"Bearer sk-test-xxx"` 的 raw，断言导出 JSON 中无该字段。

---

## 6. 测试计划（TDD，先红后绿）

| 测试文件 | 覆盖 |
|----------|------|
| `DiagnosticsExporterTests`（新） | ok / error / unconfigured 三种 status 的 JSON 结构；GLM `selected`+`availableLimits` 提炼；MiniMax/Kimi 提炼；history 附带且按 5 分钟过滤；**脱敏**（含 Authorization 的 raw → 输出无泄漏）；`schema` 版本号 |
| `DiagHistoryStoreTests`（新） | append、cap=20 淘汰最旧、5 分钟外条目导出时被过滤 |
| `QuotaErrorTests`（补） | `networkUnreachable(., underlying:)` 的 errorDescription 含 underlying |

UI 层（MenuBarController 右键项 / Popup 按钮）是薄包装，委托 `exportDiagnostics()`，不单独单测（与 v1.0.7 MenuBarSegment 同策略：核心逻辑纯函数化可测，UI 渲染薄）。

---

## 7. 入口 UI

- **右键菜单**：`MenuBarController.showContextMenu` 现有"手动刷新 / 设置 / 退出"加一项"导出诊断日志"
- **Popup**：底部栏（"设置 / 刷新于…/ v版本 / 退出"）加"诊断"按钮
- 两者调 `appState.exportDiagnostics()`，成功后短暂提示"已导出到 <路径> + 已复制到剪贴板"

---

## 8. 实现顺序（写实现计划时细化）

1. `QuotaError.networkUnreachable` 加 `underlying` + 更新调用点（fetchOne / 现有测试）
2. `DiagHistoryStore` + 测试
3. `DiagnosticsExporter` + 测试（含脱敏）
4. `AppState.exportDiagnostics()`（文件 + 剪贴板）
5. 入口（右键 + Popup）
6. bump 版本 + CHANGELOG + 走 SOP 4 步落地

---

## 9. 范围与非目标

- **不做**：系统 os_log 拉取（用 app 自存轨迹，可控且不依赖系统日志权限）
- **不做**：完整 raw dump（违反"轻量 + 相关信息"原则）
- **不做**：远程上传（只本地文件 + 剪贴板，隐私）
- history cap（20 条 / 5 分钟）与 parsedFields 字段可在后续按真实诊断反馈调整
- JSON `schema` 版本号 `QuotaMonitor-diag/1`，结构演进时升版，便于 AI 按版本解析
