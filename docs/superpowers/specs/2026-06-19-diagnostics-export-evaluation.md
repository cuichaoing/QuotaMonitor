# 诊断日志导出功能 · 评估报告

> 日期：2026-06-19
> 评估对象：v1.0.8 引入的「导出诊断日志」功能（`DiagnosticsExporter` + `DiagHistoryStore` + 右键/Popup 双入口）
> 评估依据：本次 BUG-2026-06-19-01（GLM 卡旧值）的实战定位 + 设计 spec（`2026-06-18-diagnostics-export-design.md`）+ 实现代码
> 结论先行：**价值极高（本次立决定性之功）；可用性良好（一处短板）；最该补的是「记录中间层决策」（smoothing / fingerprint）**

---

## 1. 实战复盘：它本次是怎么立功的

本次 bug（GLM 网页 3% / 状态栏 13%，刷新无效）的根因是 `applySmoothing` 误伤。定位它的**决定性证据全部来自诊断 JSON**，没有任何静态代码分析能替代：

| 诊断字段 | 值 | 揭示了什么 |
|----------|----|-----------|
| `snapshots.glm.parsedFields.selected.percentage` | **3** | API 此刻真实返回值，和网页一致 |
| `snapshots.glm.usedPercent` | **13** | 应用展示值，被某层篡改 |
| → 两者反差 | 3 vs 13 | 直接锁定「中间层（smoothing）篡改」，无需推断 API 解析对错 |
| `snapshots.glm.resetAt` | 05:07:30Z | 早于所有抓取时间（05:27+）→ 窗口早已重置 |
| `history`（6 条） | 全 13 | 证明「刷新无效」——每次都被卡回 13 |

**结论**：没有诊断功能，我看不到「API 原始值 3 vs 展示值 13」这层反差，只能猜。诊断功能把 bug 定位从「静态推测」变成「证据直读」。

---

## 2. 是否好用：良好，一处短板

**优点**
- 双入口（右键菜单 `Cmd+Opt+D` 快捷键 + Popup 底部「诊断」按钮），一键即得。
- **剪贴板 + 文件双写**：直接粘贴给 AI，也留文件存档。
- 右键入口还 `activateFileViewerSelecting` 在 Finder 定位文件（贴心）。
- JSON 结构化、字段命名清晰、带 `schema: QuotaMonitor-diag/1` 版本号（AI 可按版本解析）。
- **脱敏铁律**：递归正则清除 Authorization/Bearer/sk-/api_key（defense in depth），且只写提炼字段不 dump raw。

**短板（1 处可用性 + 1 处语义）**
- **Popup「诊断」按钮无反馈**：`PopupView.swift:83` 是 `_ = appState.exportDiagnostics()`——丢弃返回结果，用户不知道导出成功没、文件在哪、是否已复制。右键至少会弹 Finder，Popup 按钮点击后静默无声。（见迭代 F）
- **`lastRefreshAt` 语义错误**：`DiagnosticsExporter` 写的是 `iso(now)`（导出时刻），不是真正最后一次 refresh 时间。字段名误导——用户/AI 会以为「最后刷新=导出时刻」。（见迭代 D）

---

## 3. 是否有价值：极高（项目里 ROI 最高的功能之一）

- **本次实证**：根因 100% 靠诊断 JSON 锁定。
- **设计哲学对路**：记录「API 原始解析值」(`parsedFields`) 与「应用展示值」(`usedPercent`) **两层**，让 AI 能对比发现「中间层篡改」。这正是本次立功的核心——大部分配额类 bug 都是「数据在某一层被改坏」，两层对照是抓这类 bug 的通用武器。
- **一次性开发，长期受益**：每个未来 bug 都能用同一份诊断格式取证。这是基础设施级投资。

---

## 4. 迭代建议（按价值排序）

### A.（高价值）显式记录「平滑决策」——补本次最大盲区

本次根因在 `applySmoothing`，但诊断 JSON 里**没有任何 smoothing 痕迹**。AI 是靠 `usedPercent(13) vs percentage(3)` 的反差**推断**「中间发生了 smoothing」。风险：若某次 smoothing 保留值恰好 ≈ 原始值（反差小），这层 bug 就藏住发现不了。

建议 `snapshots.<kind>` 加 `smoothing` 字段：

```json
"glm": {
  "status": "ok",
  "usedPercent": 13,
  "smoothing": { "applied": true, "rawUsedPercent": 3 },
  "resetAt": "...",
  "parsedFields": {...}
}
```

`applied:true, rawUsedPercent:3, 展示=13` → 根因一目了然，无需推断。实现要点：`applySmoothing` 保留旧值时，在返回的 `ProviderQuota` 上携带「平滑前原值」（新增一个可选字段），exporter 读它写入。

### B.（高价值）记录 `windowFingerprint`

本次根因是指纹相位错位，但诊断没暴露 fingerprint 值。加一行即可让 AI 直接看到「新旧窗口指纹相同」：

```json
"glm": { ..., "fingerprint": "glm-29171666" }
```

实现极简：`DiagnosticsExporter.okDict` 加 `d["fingerprint"] = snap.windowFingerprint`。

> A + B 合起来，正好补上本次「靠反差推断中间层」的盲区，让未来所有「数据被 smoothing / 指纹逻辑篡改」类 bug 都能被诊断 JSON **直接暴露**而非靠 AI 猜。这是本次实战给出的最明确迭代方向。

### C.（中价值）补齐 spec 设计但未实现的字段

spec §4 设计了两个字段，实现遗漏：
- `isRefreshing`：导出时是否正在刷新（判断「是不是刷新中途的残态」）。
- `config.refreshIntervals`：`{active, normal, idle}`（判断「为什么这么久没更新」）。

建议补齐，与 spec 对齐。

### D.（中价值）修正 `lastRefreshAt` 语义

当前 `lastRefreshAt = iso(now)`（导出时刻）。应改为最后一次成功 refresh 时间。Popup 已用 `appState.store.lastRefreshAt` 显示「刷新于…」，exporter 同样取这个真实值传入即可。

### E.（低价值）Popup 按钮加成功反馈

`PopupView`「诊断」按钮补一个短暂提示（如改文案为「已导出+已复制」瞬时反馈，或复用右键的 Finder 定位）。

### F.（低价值）history 每条带 `resetAt`

本次靠 `snapshot.resetAt` 已够推断窗口重置。若 history 每条也带 `resetAt`，可看窗口切换轨迹，但优先级低。

### G.（配套）采纳 A/B/C/D 后 schema 升版

结构变化后 `QuotaMonitor-diag/1` → `QuotaMonitor-diag/2`，让 AI 按版本解析（spec §9 已预留升版机制）。

---

## 5. 结论与推荐

- **好用**：良好。短板仅 Popup 无反馈 + lastRefreshAt 语义（D/E，小修）。
- **价值**：极高，本次决定性立功。两层对照（parsedFields 原始值 vs usedPercent 展示值）是核心设计，应坚持。
- **最该做的迭代**：**A（记录 smoothing 决策）+ B（记录 fingerprint）**。两者直接补本次定位盲区，让「中间层篡改」类 bug 从「靠 AI 推断」变成「JSON 直读」。

建议下一轮若做，优先 A+B（含配套 G 升版），可顺手修 D+E。C（isRefreshing/refreshIntervals）次之。
