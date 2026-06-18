# 事件报告：网络错误错误归因 + 状态栏/Popup 显示不一致

| 项 | 值 |
|----|----|
| 编号 | BUG-2026-06-18-01 |
| 日期 | 2026-06-18 |
| 基线版本 | v1.0.6（git HEAD `300c208`，working tree 干净） |
| 阶段 | 【阶段 1 · 分析与计划】根因报告，待节点 1 拍板 |
| 流程 | `docs/SOP-bug-fix.md` + `superpowers:systematic-debugging` Phase 1 |
| 涉及代码 | `HTTPClient.swift` / `MenuBarController.swift` / `ProviderCardView.swift` / `AppState.swift` / `QuotaStore.swift` / 三个 Provider |

> 本报告属 B 类（需审阅）：仅本机 Marked 打开，不同步 iCloud。
> 阶段 1 铁律：报告含修复方案供决策，但**未拍板前不动任何代码**。

---

## 1. 用户报告的现象

环境：智谱 GLM 官网显示已用 **2%**，重置时间 **21:48**。

用户观察到三个 bug：

1. **状态栏与下拉菜单数值不一致**：状态栏 `G` 显示 **33**，与实际 2% 不符。
2. **网络状态误报**：网络可达，程序却显示"离线 / 网络不可达"。
3. **状态疑似串台**：Popup 里 GLM / MiniMax 卡片下方显示的是 "Claude Code" 的状态（"Claude Code 网络不可达"），且 GLM 卡片右侧标红"离线"。

附带功能需求：右键/下拉菜单增加"导出当前诊断信息日志"项，便于今后快速定位。

---

## 2. 核实与澄清（先消除两个误解）

### 2.1 "Claude Code" 其实是 "Kimi Code"

代码库里 grep "Claude" / "claude" **零命中**，`ProviderKind` 枚举只有 3 个 case：`kimi` / `minimax` / `glm`，**根本没有第四个 provider**。

`ProviderKind.swift:18`：

```swift
case .kimi: return "Kimi Code"
```

UI 上出现的 "Claude Code" 实际是 **"Kimi Code"**（Kimi 平台的显示名，记忆/口误）。也就是说，用户看到的 "Claude Code 网络不可达"，真实文案是 **"Kimi Code 网络不可达"**——这指向 **Kimi 平台抓取失败**。

### 2.2 不存在渲染层的"串台"

`PopupView.swift:49-55` 的卡片列表：

```swift
ForEach(ProviderKind.allCases.sorted(by: { $0.sortOrder < $1.sortOrder }), id: \.self) { kind in
    ProviderCardView(
        kind: kind,
        quota: appState.store.snapshots[kind],   // 按 kind 正确索引
        error: appState.store.errors[kind]       // 按 kind 正确索引
    )
}
```

每张卡片用各自的 `kind` 取各自的 `snapshots[kind]` / `errors[kind]`，**没有索引错位、没有视图复用串台**。

用户感受到的"MiniMax / GLM 显示 Kimi Code 的状态"，**真实根因是错误对象里的 provider 字段被写死成 Kimi**（见根因 A），不是渲染串台。

---

## 3. 根因（分层）

### 根因 A（铁证，最高优先级）：HTTPClient 把网络错误归因硬编码成 `.kimi`

`HTTPClient.swift:76-82`：

```swift
} catch let urlError as URLError where urlError.code == .cancelled {
    throw QuotaError.cancelled
} catch _ as URLError {
    // 透传 network 错误，由调用方决定归因到哪个 provider
    throw QuotaError.networkUnreachable(.kimi)   // [!] 硬编码 .kimi
}
```

注释写着"**由调用方决定归因到哪个 provider**"，实现却把 `.kimi` 写死了。而 `HTTPClient.send` 是无状态的——它只接收 `HTTPRequest`（url / headers / timeout），**根本不感知当前在为哪个 provider 请求**，所以它注定无法正确归因。

三个 Provider 全部直接 `try await client.send(request)` 冒泡，没有任何一层 catch 重新归因：

- `KimiProvider.swift:27`：`let response = try await client.send(request)`
- `MiniMaxProvider.swift:30`：`let response = try await client.send(request)`
- `GLMProvider.swift:33`：`let response = try await client.send(request)`

**后果链**：

```
MiniMax 网络异常  → client.send 抛 networkUnreachable(.kimi)
                 → MiniMaxProvider 不 catch，原样冒泡
                 → AppState 把它写进 errors[.minimax] = networkUnreachable(.kimi)
                 → ProviderCardView 渲染 errors[.minimax].errorDescription
                 → 该 errorDescription 用 error 内部的 .kimi 拼："Kimi Code 网络不可达"
                 → MiniMax 卡片下方显示 "Kimi Code 网络不可达"  ← 名字是别人的
```

GLM 同理。这就是用户问"为什么 MiniMax 和 GLM 下面显示的都是 Claude(Kimi) Code 的状态"的**直接答案**：错误归因被钉死在 Kimi。

> 注：`errors` 字典的 **key** 是正确的（`.minimax` / `.glm`，所以卡片挂在正确的 provider 下），但错误对象**内部**的 provider 是错的（`.kimi`），导致 `errorDescription` 文案用了 Kimi 的名字。这是"挂对了牌、写错了字"。

### 根因 B：状态栏渲染完全忽略 `errors`，与 Popup 的"error 优先"不对称

`MenuBarController.swift:195-205`（状态栏数字渲染）：

```swift
if let snap = snapshots[kind], let raw = snap.primaryUsedPercent {
    numberText = " \(snap.displayPercent ?? 0)"
    numberColor = Self.nsColor(for: raw, settings: appState.settings)
} else {
    numberText = " --"
    numberColor = NSColor.tertiaryLabelColor
}
```

状态栏**只读 `snapshots[kind]`，完全不读 `errors[kind]`**。

而 `ProviderCardView.swift:29-39`（Popup 卡片）是 **error 优先**：

```swift
if let error = error {
    statusBadge(text: errorShortText(error), color: SemanticColors.error)  // "离线" 红标
} else if let display = quota?.displayPercent ... {
    Text("\(display)%")                                                     // 百分比
}
```

两端数据源不同 → **必然显示不一致**。当某平台失败时：Popup 显示"离线"红标，状态栏这边要么显示 `--`（snapshot 已被本轮清掉），要么仍显示上一轮残留——无论哪种，都与 Popup 的"离线"对不上。

这是 bug #1（状态栏与 Popup 不一致）的**渲染层根因**，且是 v1.0.6 修"百分比取整/时序"时**没有覆盖到的第三处不一致**：v1.0.6 统一了数字本身，但没统一"成功 vs 失败"这层状态。

### 根因 C（需运行时数据确认）：状态栏 `G 33` 与"GLM 离线"同时出现，且都偏离网页 2%

这一项**静态分析无法定论**，存在时序矛盾，需要运行时诊断数据。先把矛盾摆清楚：

`AppState.refresh`（`:66-78`）每轮构造全新的 `newSnapshots` / `newErrors`，`QuotaStore.update`（`:23-27`）是**全量替换**（`self.snapshots = snapshots`，非 merge）：

```swift
for (kind, result) in results {
    switch result {
    case .success(let quota): newSnapshots[kind] = quota
    case .failure(let err):   newErrors[kind] = err
    }
}
store.update(snapshots: newSnapshots, errors: newErrors)
```

逻辑上，同一轮里 GLM **要么成功**（进 `snapshots`，状态栏与 Popup 都该显示百分比）**要么失败**（进 `errors`，状态栏该显示 `--`、Popup 显示离线），不可能"状态栏 33 + Popup 离线"并存。

但用户确实同时看到了。可能的解释（**均需运行时证实**）：

- **C1 时序差**：用户先看到状态栏 `G 33`（某轮 GLM 成功），点开 Popup 时正好赶上下一轮 GLM 失败 → Popup 离线。但 v1.0.6 已让状态栏监听 `$snapshots`（didSet 后 send），理论上失败那轮状态栏也应变 `--`。若仍显示 33，可能还有刷新未生效的边角。
- **C2 窗口口径不同**：`GLMProvider` 选的是 `TOKENS_LIMIT + unit=3`（5h token 窗口，`GLMProvider.swift:68-71`），而官网首页那个 2% 可能是另一个维度（如 TIME_LIMIT 月度）。33 可能是"解析正确、但不是用户期望看的那个窗口"。需对比 API 真实响应与官网口径。
- **C3 数据平滑残留**：`NetworkingService.applySmoothing` 会在同窗口 used 倒退时保留上一次值（`:106-116`）。若 GLM 跨窗口边界，平滑逻辑是否产生了陈旧值，需结合真实数据看。

> **C 的共同点**：都需要"当时那一刻各 provider 的 raw 响应 + 错误 + URLError.code"这类运行时证据。当前代码没有持久化诊断输出（v1.0.1 已清理 `writeDebugRaw` / `diag.txt`），所以无法回溯。**这正是用户提出的"导出诊断日志"功能要解决的问题**——见第 7 节。

---

## 4. 三个 bug 的归因映射

| 用户报告的 bug | 根因 | 确定性 |
|----------------|------|--------|
| #1 状态栏 `G 33` 与 Popup 不一致 | **B**（状态栏不读 error）+ **C**（时序/口径） | B 确定；C 待运行时 |
| #2 网络可达却报"网络不可达" | **A**（归因写死，至少名字错）+ 真实 URLError 原因待查（超时？域名拦截？Key？） | A 确定；根 URLError 待运行时 |
| #3 MiniMax/GLM 显示 Kimi(Claude) Code 状态 | **A**（错误对象内部 provider 写死 .kimi） | 确定 |

**结论**：三个 bug 同源——核心是**根因 A**。修了 A，bug #3 直接消失，bug #2 的"显示"也正确化（至少报对是谁、什么错）；根因 B 是独立的显示一致性缺陷；根因 C 需运行时数据，建议用诊断日志功能辅助定位。

---

## 5. 修复方案（供节点 1 决策，**未拍板不动代码**）

### 5.1 修根因 A：让错误归因回到正确的 provider

**决策点 A-1：归因放在哪一层？** 两个候选：

**候选 1（推荐）：HTTPClient 不再抛带 provider 的错误，改抛底层 transport 错误；各 Provider 在 `fetchQuota` 里 catch 并归因到 `self.kind`。**

`HTTPClient.swift` 改后（示意）：

```swift
} catch _ as URLError {
    // 不再硬编码 .kimi；抛与 provider 无关的底层错误，由 Provider 归因
    throw QuotaError.transport(underlying: urlError.localizedDescription)
    // （需在 QuotaError 新增 case transport / 或直接 rethrow URLError）
}
```

每个 Provider 包一层 catch（示意，以 MiniMax 为例，Kimi/GLM 同）：

```swift
do {
    let response = try await client.send(request)
    try KimiProvider.validate(response, for: kind)
    ...
} catch let err as QuotaError where err.isTransportLike {
    throw QuotaError.networkUnreachable(kind)   // 用 self.kind 归因，正确
} 
```

- 优点：归因权回到"知道自己是谁"的 Provider，语义正确；HTTPClient 保持无状态纯净。
- 代价：3 个 Provider 各加一层 catch；`QuotaError` 可能要加一个不含 provider 的 transport case（或复用现有结构）。

**候选 2：给 `HTTPRequest` 加一个 `provider: ProviderKind?` 字段，HTTPClient 据此归因。**

- 优点：改动集中在一处。
- 代价：污染 HTTPClient 的 provider 感知（破坏无状态设计），且 `HTTPRequest` 是通用结构，塞 provider 不优雅。

**决策点 A-2：`networkUnreachable` 的归类是否过宽？** 当前所有 `URLError`（超时 / TLS / DNS / 连接拒绝 / 代理…）一律归 `networkUnreachable`。建议按 `URLError.code` 细分：超时→可重试的"超时"；`notConnectedToInternet`→真"网络不可达"；其他→"连接失败"。这能直接回答 bug #2"网络可达为何报不可达"——很可能并非真不可达，而是超时/TLS 被笼统归为此类。**此项建议在诊断日志拿到真实 `URLError.code` 后再定方案。**

### 5.2 修根因 B：状态栏反映 error 状态

**决策点 B-1：某平台失败时，状态栏那个字母位显示什么？** 候选：

- (a) 显示 `!`（如 `G !`）+ 红色，表示该平台当前异常；
- (b) 显示 `--` + 中性灰（当前失败分支已是 `--`，但需确保失败时确实落到这里，而非残留旧值）；
- (c) 保留上一次成功值 + 叹号/暗色，表达"陈旧"。

推荐 **(a)**：与 Popup 的"离线"红标语义对齐，最不易误解。实现上 `refreshStatusItemTitle` 增加 `errors[kind]` 判断分支即可。

**决策点 B-2：是否同时让状态栏在"全平台失败"时有更显眼提示**（如整条变红/加叹号）。可选增强。

### 5.3 根因 C：暂不盲改，先用诊断日志取证

C 涉及运行时时序与 GLM 响应口径，**禁止在没证据前猜测式修改**（`systematic-debugging` 红线）。建议：

1. 先实现第 7 节的"诊断日志导出"功能；
2. 复现时导出日志，拿到 GLM 的 raw 响应、各 provider 的 error、时间戳；
3. 据此判断 C1/C2/C3 哪个成立，再对症修复。

---

## 6. 验证计划（TDD，阶段 2 执行）

节点 1 拍板后，按 `superpowers:test-driven-development`：

- **根因 A 测试**：构造 MiniMax / GLM 的 `URLProtocol` mock 让 `client.send` 抛 `URLError`，断言各自 Provider 返回的 error **内部 provider 是 minimax / glm**（不是 kimi）。当前测试 `NetworkingServiceTests` / `*ProviderTests` 未覆盖"跨 provider 网络错误归因"，是漏网。
- **根因 B 测试**：`MenuBarController` 的标题渲染目前无单测（UI 层）。可抽出纯函数 `statusSegment(for:snapshot:error:settings:)` 做可测设计，断言有 error 时返回 `!` 而非旧百分比。
- **回归**：`swift test` 需保持 110/110（新增后递增），且不破坏 v1.0.6 的 `displayPercent` 一致性测试。

---

## 7. 待确认决策点（节点 1 需拍板）

| # | 决策点 | 我的推荐 |
|---|--------|----------|
| A-1 | 错误归因放哪层 | 候选 1（Provider 各自 catch 归因到 self.kind） |
| A-2 | networkUnreachable 是否细分 | 先靠诊断日志取证真实 URLError.code 再定 |
| B-1 | 状态栏失败时显示 | (a) `G !` + 红色 |
| B-2 | 是否做"全失败"整条提示 | 可选，暂不做 |
| C | 33 vs 2% / 离线时序 | 不盲改，先取证 |
| F | 诊断日志导出功能 | 独立 feature，走 brainstorming（见下） |

**执行顺序建议**：A（确定且高价值）→ B（确定）→ F（功能，且能取证 C）→ C（取证后再修）。

---

## 8. 附：诊断日志导出功能（feature）需求初稿

> 这是新功能，按规矩走 `superpowers:brainstorming`，不与本报告的 bug 修复混拍。先记需求，待 bug 修复方向定后再单独设计。

**用户意图**：今后发现问题时，一键导出"当前诊断信息日志"，便于快速定位（也直接服务于本次根因 C 的取证）。

**初步需求（待 brainstorm 细化）**：
- 入口：状态栏右键菜单 + Popup，新增"导出诊断日志"项（`MenuBarController.showContextMenu` :133-143 当前只有 手动刷新/设置/退出）。
- 内容：各 provider 最近一次的 `result`（成功 raw 摘要 / 失败 error 类型 + `URLError.code`）、`capturedAt` 时间戳、`lastRefreshAt`、enabled 平台、阈值设置、app 版本。**严禁包含 API Key**（Key 走 Keychain，日志里只记"已配置/未配置"）。
- 输出：保存到 `~/Downloads/QuotaMonitor-diag-<时间戳>.txt`（或 .md），并弹通知/提示路径；可选自动 `open` 所在文件夹。
- 落地：需在 `NetworkingService` / `AppState` 留存"最近一轮的完整 result + 底层 error 描述"（当前 `QuotaError` 丢了 `URLError.code`，要补）。

**与本次 bug 的协同**：先做这个功能，复现 bug #1/#2 时导出日志，就能拿到根因 C 缺的运行时证据，避免盲改。

---

## 9. 结论

- 三个 bug **同源于根因 A**（HTTPClient 错误归因硬编码 `.kimi`），这是写死 + 架构（无状态 client 却要抛带 provider 的错）双重问题。
- 根因 B 是独立的"状态栏不读 error"显示缺陷，是 v1.0.6 未覆盖的第三处一致性漏洞。
- 根因 C 需运行时数据，**禁止盲改**，建议用诊断日志功能取证。
- 功能需求（诊断日志导出）独立走 brainstorming。

**停在节点 1，等你拍板**：确认第 7 节决策点（尤其 A-1 / B-1），以及是否同意"先修 A、B，再做诊断日志功能，最后取证修 C"的顺序。
