# Changelog

QuotaMonitor 版本变更历史。

---

## [1.0.9] - 2026-06-19

**Bug 修复：GLM 额度卡在旧值（网页 3% / 状态栏 13%，刷新无效）** — 服务端窗口重置后真实值回落，被数据平滑逻辑误判为「同窗口倒退」而永久卡住。详见 `docs/incident-reports/2026-06-19-glm-smoothing-stuck-at-stale-value.md`。

### 修复

- **窗口指纹相位错位（根因）**：`ProviderQuota.windowFingerprint` 此前用 `capturedAt/18000` 机械切 5h 桶，与服务端真实窗口边界（`resetAt`）相位错位。真实窗口在桶内重置时指纹不变，`applySmoothing` 把新窗口的合法低值（如 3%）误判为「同窗口被动流失倒退」，丢弃真实值、保留旧值（如 13%），导致刷新多少次都不变。改为锚定 `primaryWindow.resetAt`（取整到分钟吸收服务端毫秒抖动）：同一 `resetAt` = 同一窗口（防抖 / 告警去重仍生效）；窗口重置 → `resetAt` 变 → 指纹变 → 平滑跳过 → 接受真实新值。连带修正 `AlertStateMachine` 去重语义——窗口重置后越过阈值能正确重新告警（旧实现跨桶边界会漏报）

### 测试

- 新增 `NetworkingServiceTests.testSmoothing_acceptsLowerValueWhenServerWindowResets`：GLM 上窗口 13% → 窗口重置后真实 3%，断言接受 3（修复前卡在 13）
- 改写 `ProviderQuotaTests` 指纹用例为 resetAt 语义：`testWindowFingerprint_stableForSameResetAt`（同 resetAt 同指纹）、`testWindowFingerprint_changesWhenServerWindowResets`（resetAt 变则指纹变）、`testWindowFingerprint_distinguishesPlatforms`
- `swift test` → 131/131 通过（1.0.8 为 130，本轮净增 1）

### 已知后续（本轮未做）

- GLM 窗口显示「3h」应为「5h」：`GLMProvider` 把 `unit=3` 直接当小时数，实际 unit=3 代表 5h 窗口。同源小问题，不影响主数值，待单独修复

---

## [1.0.8] - 2026-06-18

**新功能：诊断日志导出** — 一键"拍照式"导出当前配额状态镜像 + 近期刷新轨迹为脱敏 JSON（剪贴板 + 文件双写），供 AI 快速诊断。详见 `docs/superpowers/specs/2026-06-18-diagnostics-export-design.md`。

### 新增
- 右键菜单 / Popup 加"导出诊断日志"：写 `~/Downloads/QuotaMonitor-diag-<ts>.json` + 复制到剪贴板；右键还在 Finder 定位文件
- `DiagHistoryStore`：ring buffer 存最近 20 条刷新轨迹，导出时按 5 分钟窗口过滤
- `DiagnosticsExporter`：纯逻辑导出脱敏 JSON（各平台提炼关键字段如 GLM selected/availableLimits，非 raw dump；递归正则清除 Authorization/Bearer/Key 作安全网）
- `QuotaError.networkUnreachable` 加 `underlying`，错误信息能说清"为什么不可达"（落地 incident report A-2）

### 测试
- 新增 `DiagnosticsExporterTests`（6）、`DiagHistoryStoreTests`（4）；补 `QuotaErrorTests` underlying（2）
- `swift test` → 130/130 通过

---

## [1.0.7] - 2026-06-18

**Bug 修复：网络错误错误归因 + 状态栏忽略 error 状态** — 修复"MiniMax/GLM 显示 Kimi Code 网络不可达"与"状态栏数字与 Popup 离线不一致"。详见 `docs/incident-reports/2026-06-18-error-misattribution-statusbar-mismatch.md`。

### 修复

- **网络错误归因错误（根因 A，总根因）**：`HTTPClient.swift` 此前把所有 `URLError` 硬编码成 `networkUnreachable(.kimi)`，而 HTTPClient 无状态、不感知当前请求属于哪个 provider。后果：MiniMax / GLM 一遇网络异常，错误对象内部 provider 被钉死成 Kimi，UI 显示 "Kimi Code 网络不可达" 挂在错误的卡片下（用户误以为"状态串台"）。改为 HTTPClient 不再归因、`URLError` 原样冒泡，由 `NetworkingService.fetchOne`（持有当前 `kind`）归因为 `networkUnreachable(kind)`
- **状态栏忽略 error 状态（根因 B）**：`MenuBarController.refreshStatusItemTitle` 此前只读 `snapshots`、完全不读 `errors`，与 Popup 的 error 优先渲染不对称——某平台失败时状态栏仍显示旧百分比或 `--`，而 Popup 显示"离线"红标。新增纯值类型 `MenuBarSegment`（error > 成功快照 > 占位 三级决策），状态栏失败时显示 `!` 红色，与 Popup 对齐

### 测试

- 新增 `NetworkingServiceTests.testNetworkError_attributedToCallingProvider_notHardcodedKimi`：验证 MiniMax / GLM 网络错误归因到各自 kind（修复前被钉死成 kimi）
- 新增 `MenuBarControllerTests`（5 用例）：`MenuBarSegment.resolve` 的 error 优先、成功值、占位、取整一致性
- `MockURLProtocol.handler` 扩展为可 `throw`（支持模拟 `URLError`）
- `swift test` → 118/118 通过（本轮新增 6 个用例）

### 已知后续（按既定顺序，本轮未做）

- **根因 C**（GLM `G 33` vs 网页 2% vs "离线" 时序）：需运行时诊断数据，待"诊断日志导出"功能落地后取证再修，禁止盲改
- **诊断日志导出功能**（右键/下拉菜单加"导出诊断日志"）：独立 feature，走 brainstorming
- **文档元信息滞后**：README 测试数（实际 118）、CLAUDE.md 版本/测试数待统一更新

---

## [1.0.6] - 2026-06-18

**Bug 修复：状态栏与 Popup 百分比显示不一致**

### 修复

- **状态栏与 Popup 数字不同步**（实测：状态栏 MiniMax 显示 2、Popup 显示 1%）。双层根因，缺一不可：
  - **时序滞后（主因）**：`MenuBarController` 监听 `store.objectWillChange`，而 `snapshots` 是 `@Published`——`objectWillChange` 在 `willSet` 触发、新值尚未写入，导致状态栏读到上一周期的旧快照、滞后一个刷新周期。改为监听 `store.$snapshots`（`didSet` 后 send），读到当前快照。此陷阱与 v1.0.2 修阈值 slider 时遇到的同类（项目陷阱表已记录），`snapshots` 这条此前漏修
  - **取整不一致（次因）**：状态栏 `Int()` 截断 vs Popup `String(format:"%.0f")` 四舍五入，同一非整数值差 1。新增 `ProviderQuota.displayPercent`（四舍五入、`.5` 向上）作为两处共用的显示值；颜色阈值判定仍用原始 `Double` 的 `primaryUsedPercent`，避免边界颜色错位

### 测试

- 新增 `ProviderQuotaTests`：`displayPercent` 四舍五入边界（`0.5→1`、`1.6→2`、`2.5→3`、`59.6→60`）及无窗口返回 `nil`

## [1.0.5] - 2026-06-18

**Bug 修复与 UI 完善**

### 修复

- **保存 Key 后 popup 仍显示"无 KEY"**：`ProviderKeyRow.save()` / `delete()` 在 Keychain 写入/删除成功后立即触发 `AppState.refresh()`，状态栏与 popup 实时同步
- **查看 Key 时闪退**：`TextField` / `SecureField` 切换时加 `.id(showKey)`，强制 SwiftUI 重新创建视图，规避 macOS 在 secure/plain 文本框间切换的已知崩溃

### 新增

- **版本号显示**：popup 底部显示当前应用版本号（读取 `Info.plist` 的 `CFBundleShortVersionString`）
- **状态栏图标**：状态栏按钮左侧增加 SF Symbol 模板图标，解决 DMG 安装版"图标空白"问题

---

## [1.0.4] - 2026-06-17

**新增开机自动启动功能**

### 新增

- **开机自启**：设置面板新增"登录时自动启动 QuotaMonitor"选项，使用 Apple 主推的 SMAppService API
- **系统设置跳转**：当 macOS 需要授权时，一键打开"系统设置 → 登录项"

### 变更

- 最低系统要求从 macOS 12 提升至 macOS 13（SMAppService 需要）

### 技术细节

- 新增 `LoginItemManager` 封装 SMAppService 注册/注销/状态查询
- `SettingsStore` 新增 `launchAtLogin` 持久化字段
- `AppDelegate` 启动时同步 SMAppService 与设置状态

---

## [1.0.3] - 2026-06-17

**修复 GitHub Release 的 .dmg 安装包无法启动的问题** — 根因：CI 打包步骤未复制 `Info.plist`，导致 .app bundle 结构不完整。

### 修复

- **CI 打包修复**：`.github/workflows/release.yml` 的 Package .app 步骤现在会复制 `QuotaMonitor/Resources/Info.plist`
- **源码管理 Info.plist**：将 `Info.plist` 和 `QuotaMonitor.entitlements` 纳入版本控制，本地构建与 CI 使用同一份配置
- **release.sh 更新**：版本号 bump 现在修改源代码中的 `Info.plist`，并同步到本地 build 目录
- **README 构建步骤更新**：本地手动打包步骤加入 `Info.plist` 复制

---

## [1.0.2] - 2026-06-17

**UI 修复** — 阈值颜色实时响应设置变更，阈值支持数字框精确输入。

### 修复

- **阈值 slider 颜色失效**：`MenuBarController.nsColor(for:)` 改读 `SettingsStore`，`observeState()` 用 `Publishers.Merge3` 监听 3 个 `$publisher`，避免 `objectWillChange` 1 帧滞后
- **ThresholdSlider 加可编辑 TextField**：slider 拖动 + 数字框输入双向同步

### 已知问题

- GLM 周维度（`TOKENS_LIMIT + unit=6`）和 MCP 月度（`TIME_LIMIT + unit=5`）暂未展示

---

## [1.0.1] - 2026-06-17 (热修)

**3 平台 Provider 解析逻辑全部按真实 API 响应重写** — 根因：v1.0 全部基于猜测的字段路径，实际响应结构与假设不符。

### 修复

- **Kimi**：`limits[0].detail.{limit, used, resetTime}` 嵌套结构（字段值是字符串）
- **MiniMax**：用 `current_interval_remaining_percent` 字段反算 usedPercent（"general" 模型优先）
- **GLM**：`data.limits` 结构（不在顶层），`percentage` 直接给百分比，`nextResetTime` 是毫秒时间戳
- **GLM 5h 窗口识别**：用户反馈网页第一个百分比才是 5h 配额，应选 `type="TOKENS_LIMIT" + unit=3`（不是 `TIME_LIMIT + unit=5`，那是 MCP 月度额度）

### 变更

- 105 个测试用例（v1.0 是 95；新增 10 个反直觉字段测试）
- `swift test` → 105/105 通过，~0.5s
- 清理所有 v1.0 调试代码（GLMProvider os_log + writeDebugRaw / NetworkingService catch diag / AppState refresh diag）

### 已知问题

- GLM 数据为 5h token 窗口的 `TOKENS_LIMIT` 维度（`unit: 3`），周维度（unit=6）和 MCP 月度（TIME_LIMIT+unit=5）暂未展示

---

## [1.0.0] - 2026-06-17

**正式版发布** —— macOS 状态栏原生应用，监控 Kimi / MiniMax / GLM 三大 AI 平台 5h 配额。

### 新增

- **状态栏常驻**：NSStatusItem + NSPopover，点击展开 3 平台卡片
- **3 平台并行抓取**：actor + withTaskGroup，平均 200ms 内完成
- **智能节流**：4 级自适应（活跃 30s / 普通 60s / 空闲 5m / 休眠暂停）
- **数据平滑**：同窗口 used 不倒退，对治 MiniMax 被动流失
- **Keychain 安全存储**：API Key 走 macOS Keychain
- **设置面板**：3 平台 Key 管理 + 启用开关 + 3 级阈值调节 + 刷新频率微调
- **系统通知告警**：UNUserNotificationCenter 3 级（75/90/99%），5h 窗口指纹去重
- **Bark 远程推送**：iOS 端 HTTP 推送（可选）
- **首次启动引导**：未配置 Key 时 popup 顶部显示引导
- **95 个单元测试**，覆盖核心模型 / 3 平台 Provider / 网络 / 调度 / 设置 / 告警 / 推送

### 验证

- `swift test` → 95/95 通过，~0.5s
- macOS 12+ 编译，0 warning
- 关键反直觉场景测试：
  - MiniMax `current_interval_usage_count` 是"剩余"非"已用"
  - GLM 禁止 "Bearer " 前缀
  - Kimi 必须带 `KimiCLI/1.30.0` User-Agent

### 文件

- 40 个 Swift 源文件 + 13 个测试文件
- 总代码量约 4000 行

---

## [0.6.0] - 2026-06-17 (内测)

- 引入 Bark 远程推送客户端（BarkClient + 4 测试）
- SettingsStore 加 Bark 配置（启用开关 + 服务器 + device key）

## [0.5.0] - 2026-06-17 (内测)

- NotificationManager（UNUserNotificationCenter 封装）
- AlertStateMachine（3 级阈值 + 5h 窗口指纹去重，12 测试）
- AlertLevel（none/warning/critical/danger）
- 启动时申请通知权限

## [0.4.0] - 2026-06-17 (内测)

- SettingsStore（Keychain + UserDefaults 统一封装，18 测试）
- SettingsView（3 平台 Key 输入 + 阈值 slider + 高级频率）
- SettingsWindowController（单例 NSWindow）
- AppState 接入 SettingsStore，从 enabledProviders 决定 fetchAll
- MenuBarController 右键菜单加"设置"入口
- PopupView 加"设置"入口

## [0.3.0] - 2026-06-17 (内测)

- 9 个测试文件 + MockURLProtocol helper
- 61 个测试用例全部通过
- 关键反直觉断言（MiniMax 字段、GLM 鉴权、Kimi User-Agent）

## [0.2.0] - 2026-06-17 (内测)

- UI 壳子：DesignTokens + QuotaStore + AppState
- 4 个 Popup 组件（ProgressBar / CountdownLabel / ProviderCardView / PopupView）
- MenuBarController（NSStatusItem + NSPopover + Combine 监听）
- AppDelegate + @main，accessory 模式不显示在 Dock

## [0.1.0] - 2026-06-17 (内测)

- Core 层：ProviderKind / QuotaWindow / ProviderQuota / ActivityLevel
- QuotaError 完整定义（isRetryable / isUserActionable 矩阵）
- KeychainStore（真机 Keychain + InMemory mock）
- HTTPClient（URLSession 极薄包装）
- 3 平台 Provider 实现
- NetworkingService（actor 并行抓取 + 数据平滑）
- SmartRefreshScheduler（4 级节流 + NSWorkspace 监听）
- SystemActivityMonitor（IDE 前台检测）
- AF Inventory 注册：#68 standalone-macos-app
