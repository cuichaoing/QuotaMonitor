# 事故报告：GLM 每小时额度卡在旧值（网页 3% / 状态栏 13%）

> 编号建议：BUG-2026-06-19-01
> 报告日期：2026-06-19
> 阶段：阶段 1 · 分析与计划（未动代码，待拍板）
> 诊断来源：`~/Downloads/QuotaMonitor-diag-20260619-133135.json`（appVersion 1.0.8）

---

## 1. 现象

- 智谱 GLM 网页后台显示每小时配额「已用 3%」。
- 状态栏（与 Popup）显示 GLM 数值为 **13**，颜色为绿色（正常区间）。
- 手动点击「刷新」**多次**，数值始终不变，仍是 13。
- Kimi / MiniMax 数值正常（均为 0）。

一句话：**服务端真实值是 3，应用持续显示 13，刷新无效。**

---

## 2. 证据链（直接来自诊断 JSON）

诊断文件同时记录了「API 原始返回值」和「应用展示值」，两者打架，铁证如下：

```
snapshots.glm:
  parsedFields.selected          → { percentage: 3, type: TOKENS_LIMIT, unit: 3 }   ← API 真实返回，与网页 3% 一致
  parsedFields.availableLimits   → [
        { percentage: 10, TIME_LIMIT,    unit: 5 },   ← MCP 月度
        { percentage:  3, TOKENS_LIMIT,  unit: 3 },   ← 5h 配额（已用 3%）
        { percentage: 49, TOKENS_LIMIT,  unit: 6 }    ← 周维度
  ]
  usedPercent                    → 13                         ← 应用展示值（错！应为 3）
  resetAt                        → 2026-06-19T05:07:30Z       ← 服务端窗口结束时间
  window                         → "3h"

history（6 次抓取，时间 UTC）：
  05:27:21 / 05:27:28 / 05:27:53 / 05:28:57 / 05:30:00 / 05:31:03
  → glm.pct 全部 = 13（一次都没回落到 3）

exportedAt = 2026-06-19T05:31:35Z（抓取发生在 05:27~05:31）
```

关键反差：

| 维度 | 值 | 含义 |
|------|----|----|
| API 原始 `percentage` | **3** | 真实已用，和网页一致 |
| 应用展示 `usedPercent` | **13** | 被某层逻辑篡改 |
| `resetAt` | **05:07:30Z** | **早于所有抓取时间（05:27+），说明窗口早已重置** |

> [!] `selected.percentage=3` 是 `DiagnosticsExporter` 直接从**当前 raw payload** 里现取的（`QuotaMonitor/Services/Diagnostics/DiagnosticsExporter.swift:135-155`），证明 API 此刻确实返回 3。而 `usedPercent=13` 来自经过平滑处理后的 `primaryWindow`。**3 是真的，13 是应用自己造的。**

---

## 3. 根因（分层）

### 3.1 直接原因：数据平滑逻辑丢弃了真实新值

`QuotaMonitor/Services/Networking/NetworkingService.swift:104-124` 的 `applySmoothing`：

```swift
private func applySmoothing(_ quota: ProviderQuota, kind: ProviderKind) -> ProviderQuota {
    guard let prev = lastSnapshot[kind],
          let prevWin = prev.primaryWindow,
          let curWin = quota.primaryWindow,
          prev.windowFingerprint == quota.windowFingerprint else {
        return quota   // 新窗口或首次，无需平滑
    }
    if curWin.used < prevWin.used {
        // 倒退：保留上一次（可能是被动流失后回弹）
        return ProviderQuota(... primaryWindow: prevWin ...)   // ← 把真实新值 3 丢了，回退到旧值 13
    }
    return quota
}
```

设计初衷（注释）：对治 **MiniMax** 短窗口内的「被动流失」（used 无故倒退）。规则是：**同一窗口指纹下，新值不能小于旧值，否则视为异常回弹，保留旧值。**

它在 GLM 上误伤：真实窗口重置后 used 合理地从 13 跌到 3，但平滑逻辑判定「3 < 13 = 倒退」，于是**永远保留 13**。这正好解释了「刷新多少次都不变」——每次刷新都重新走这条 `cur < prev → 保留 prev` 的分支。

### 3.2 根本原因：窗口指纹与服务端真实窗口「相位错位」

为什么平滑逻辑会把「跨窗口重置」误判成「同窗口倒退」？因为指纹算错了。

`QuotaMonitor/Core/Models/ProviderQuota.swift:58-61`：

```swift
/// 用于去重状态机的窗口指纹（同窗口去重）
/// 公式：floor(epoch / 18000)，每 5h 一个 ID
public var windowFingerprint: String {
    let epoch = Int(capturedAt.timeIntervalSince1970)
    return "\(provider.rawValue)-\(epoch / 18000)"
}
```

这个指纹用**抓取时刻的 Unix 时间**除以 18000 秒（5h）来切桶。它和服务端配额窗口的**真实边界（`resetAt`，如 05:07:30）完全无关**——只是按 epoch 机械切 5 小时。

两者粒度都是 5h，但**相位对不齐**：

```
（UTC）
应用 epoch 分桶边界： │←── 分桶 97239（05:00 ~ 10:00）──→│
                     05:00:00                        10:00:00
GLM 真实窗口 resetAt：────────────── 05:07:30 重置 ──────────────
                     ├─ 上窗口 used≈13 ─┤├── 新窗口 used=3 ──→
应用 fingerprint：   │←────── 全程 glm-97239（始终不变）──────→│
```

分桶 97239 对应 epoch `[1750302000, 1750320000)` = UTC `05:00:00 ~ 10:00:00`。GLM 真实窗口在 **05:07:30** 重置，落在该分桶**内部**。后果：

- 05:00~05:07:30 抓取：上窗口真实 used=13，记 `lastSnapshot[.glm]=(used=13, fp=glm-97239)`。
- 05:07:30 真实窗口重置，新窗口 used=3。
- 05:07:30~10:00 抓取：raw 返回 3，构造 `quota=(used=3, fp=glm-97239)`——**指纹和上次相同**。
- `applySmoothing`：同指纹 + `3 < 13` → 判定倒退 → 保留 13。

> [!] 粒度相同但相位错位，是最隐蔽的失败模式：大多数时候真实重置恰好落在分桶边界附近，看似正常；一旦真实重置落在分桶内部（如本次 05:07:30 落在 05:00~10:00 桶内），就翻车。这正是「偶发、刷新无效」的特征来源。

### 3.3 附带发现（次要 bug，同源）：窗口显示「3h」而非「5h」

`GLMProvider.swift:80`：

```swift
let unitHours = KimiProvider.numericValue(entry["unit"]).map { Int($0) } ?? 5
...
displayName: "\(unitHours)h"   // unit=3 → 显示 "3h"
```

把 GLM 的 `unit` 字段值（3）直接当小时数。但按项目陷阱表，`TOKENS_LIMIT + unit=3` 是 **5 小时**窗口。诊断 `window: "3h"` 即此 bug 的表现。与主 bug 同源（对 `unit` 语义理解不准），建议顺带修，但**不影响主数值**，优先级低于主修。

---

## 4. 时序还原（完整复现链）

1. 应用本次启动（`lastSnapshot` 为内存变量，不持久化，见 `NetworkingService.swift:23`）。启动后首次抓取落在 GLM 上窗口（约 00:07~05:07 真实窗口），真实 used≈13，写入 `lastSnapshot[.glm]`，指纹 `glm-97239`。
2. **05:07:30Z** GLM 真实 5h 窗口重置，新窗口真实 used=3（与网页一致）。
3. 05:27:21Z 起，应用多次抓取：raw 均返回 `percentage=3`，但因 epoch 分桶仍为 97239（05:00~10:00 未过完），指纹与上次相同。
4. `applySmoothing` 每次都判定 `3 < 13`，保留 13。`store.snapshots[.glm].primaryWindow.used=13`，`displayPercent=13`，诊断 `usedPercent=13`。
5. 用户手动刷新 → `AppState.refresh()` → `fetchAll` → `fetchOne` → `applySmoothing` → 同样被卡回 13。

> 13 是上个真实窗口的真实使用量（5h 用了 13%，合理；对照周维度 49%、MCP 月度 10%）。并非凭空产生。

---

## 5. 修复方案（待你拍板选其一）

### 方案 A（推荐）：指纹锚定服务端窗口 `resetAt`

把「抓取时刻分桶」改为「服务端窗口身份」。同一 `resetAt` 即同一窗口，窗口重置则指纹变化。

改 `ProviderQuota.swift`：

```swift
// ── 改前 ──
public var windowFingerprint: String {
    let epoch = Int(capturedAt.timeIntervalSince1970)
    return "\(provider.rawValue)-\(epoch / 18000)"
}

// ── 改后 ──
/// 窗口指纹：锚定服务端真实窗口（resetAt），而非抓取时刻。
/// 同一 resetAt = 同一窗口（平滑防抖 / 告警去重生效）；
/// 服务端窗口重置 → resetAt 变 → 指纹变 → 接受真实新值。
/// resetAt 取整到分钟，吸收服务端毫秒级抖动。
public var windowFingerprint: String {
    let resetEpoch = Int(primaryWindow?.resetAt.timeIntervalSince1970 ?? 0) / 60
    return "\(provider.rawValue)-\(resetEpoch)"
}
```

- 连带收益：`AlertStateMachine` / `NotificationManager` 的同窗口去重也随之锚定真实窗口——新窗口重置后重新越过阈值能**正确告警**（当前 epoch 分桶方式在窗口跨桶边界时会漏报）。
- 风险：`primaryWindow` 为 nil 时退化为 `provider-0`，可接受（无窗口本就不该平滑/告警）。
- 需同步改 `ProviderQuotaTests` 的指纹用例（用 `resetAt` 构造）。

### 方案 B（备选，最小止血）：平滑只对 MiniMax 生效

`NetworkingService.swift`：

```swift
private func applySmoothing(_ quota: ProviderQuota, kind: ProviderKind) -> ProviderQuota {
    guard kind == .minimax else { return quota }   // 平滑本就只为 MiniMax 设计
    // ... 原逻辑
}
```

一行止血。缺点：治标——指纹相位错位的根因仍在，MiniMax 跨真实窗口重置时仍可能误伤（用户暂未遇到）。

### 方案 C（备选）：平滑前做「窗口重置检测」

```swift
// 在 applySmoothing 内，fingerprint 判断之外再加：
if let curWin = quota.primaryWindow, curWin.resetAt != prevWin.resetAt {
    return quota   // 窗口已换，直接采用新值
}
```

与方案 A 等价但检测点散落在 `applySmoothing`。方案 A 把「窗口身份」收敛到单一可信源（fingerprint），更统一。

> 倾向：直接上 **方案 A**（根治 + 告警也受益）。若想先快速止血再根治，可 B 先行、A 随后，但 A 本身改动很小，没必要分两步。

---

## 6. 验证计划（TDD，待开工后执行）

1. **失败测试先写**（`NetworkingServiceTests` 或新建 smoothing 用例）：
   - 用例 1：构造 GLM prev（`resetAt=T1, used=13`）与 cur（`resetAt=T2, used=3`，T2>T1 即窗口已换），断言 `applySmoothing` 返回 cur（used=3）。→ 当前代码会失败（返回 13）。
   - 用例 2：同 `resetAt`（同窗口），cur.used 抖动下降，断言保留 prev（防抖仍有效）。→ 防止修过头、破坏 MiniMax 防抖。
2. **`ProviderQuotaTests`**：`resetAt` 相同 → 同指纹；`resetAt` 不同 → 不同指纹。
3. `swift test` 全过、无回归（当前 130 用例基线）。
4. （可选）附带修 `unit→小时` 映射后，补 GLM window 显示为 5h 的断言。

---

## 7. 待你确认的决策点

| # | 决策 | 我的建议 |
|---|------|----------|
| 1 | 主修选哪个方案 | **方案 A**（锚定 resetAt） |
| 2 | 附带 bug「window 显示 3h」是否一并修 | 顺带修（同源，且让诊断/UI 一致） |
| 3 | 是否新增独立编号 BUG-2026-06-19-01 | 是 |

拍板后进入阶段 2（TDD 改码 + 测试 + 版本号 + CHANGELOG + commit），再汇总等你确认才替换 `/Applications` 与推 GitHub。
