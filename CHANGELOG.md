# Changelog

QuotaMonitor 版本变更历史。

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
