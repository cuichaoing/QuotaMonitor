# QuotaMonitor v1.0.2 会话交接临时记忆

> 写入日期：2026-06-17
> 写入原因：用户从 AgentForge 母港对话框切换回 QuotaMonitor 项目自己的对话框
> 适用对象：QuotaMonitor 项目自己的 sub-agent（唤醒后第一件事读这份文件）

---

## 0. 当前状态

- **版本**：v1.0.2（已发布）
- **测试**：105/105 全过，~0.5s
- **App 状态**：最后构建的 .app 在 `build/QuotaMonitor.app`，ad-hoc 签名已生效，UI 已部署
- **进程**：用户已重启过一次；当前可能正在运行，也可能已退出
- **平台状态**：3 平台（Kimi / MiniMax / GLM）全部 fetch 成功，无 `diag.txt` 错误

## 1. 完整修复历史（本会话内）

### v1.0.0 → v1.0.1：3 平台 Provider 按真实 API 重写

| 平台 | v1.0 错误假设 | 真实响应 |
|------|--------------|----------|
| Kimi | 顶层 `limit/used` 字段 | `limits[0].detail.{limit, used, resetTime}` 嵌套（值是字符串） |
| MiniMax | `current_interval_usage_count` 当"剩余"反算 | `current_interval_remaining_percent` 是"剩余"，`used = 100 - x` |
| GLM | 顶层 `limits[i].usage` 百分比 | `data.limits[i].percentage` 直接给百分比（**data 不是顶层**） |

**GLM 5h 窗口识别（用户 2026-06-17 反馈修正）**：
- ❌ 错误：`type="TIME_LIMIT" + unit=5` → 这是 MCP 月度额度
- ✅ 正确：`type="TOKENS_LIMIT" + unit=3` → 5h 配额

| 网页显示 | JSON 字段 | 含义 | 是否用 |
|---------|----------|------|--------|
| 0% | `TOKENS_LIMIT + unit=3` | 5h 配额 | **是（主窗口）** |
| 32% | `TOKENS_LIMIT + unit=6` | 周配额 | 否（暂未展示） |
| 9% | `TIME_LIMIT + unit=5` | MCP 月度 | 否（用户不用关心） |

### v1.0.1 → v1.0.2：UI 颜色 bug + 数字输入框

**修复 1：阈值 slider 颜色失效**
- 根因：`MenuBarController.nsColor(for:)` 用了**硬编码**阈值（75/90/99），完全没读 `SettingsStore`
- 修复：
  1. `nsColor(for:)` 改签名 `(for: Double, settings: SettingsStore)`，从 `appState.settings` 读 `warningThreshold/criticalThreshold/dangerThreshold`
  2. `observeState()` 加 `Publishers.Merge3(s.$warningThreshold, s.$criticalThreshold, s.$dangerThreshold)` 监听 3 个阈值属性
  3. 用 `$publisher` 而非 `objectWillChange`：前者 `didSet` 后 send（新值已稳定），后者 `willSet` 触发（值未写入，1 帧滞后）

**修复 2：ThresholdSlider 加可编辑 TextField**
- 把只读 `Text("\(Int(value))%")` 替换为 `TextField` + "%" 标签
- `@State private var textValue` 缓冲输入（slider 拖动时不同步，避免光标跳动）
- `@FocusState private var isFocused` 跟踪焦点
- `.onSubmit { commit() }` + 失焦时自动 commit
- commit 时 `Int` 解析 + `clamp` 到 range + 写回 `value`
- 非法输入恢复原值（不污染 binding）

## 2. 关键技术陷阱（防止再踩）

| 陷阱 | 说明 |
|------|------|
| GLM 鉴权 | Authorization 头**禁止** "Bearer " 前缀，裸 Token 直接传 |
| Kimi User-Agent | 必须 `KimiCLI/1.30.0` 才命中 Coding Plan 专属额度 |
| GLM 5h 窗口识别 | `TOKENS_LIMIT + unit=3`（不是 `TIME_LIMIT + unit=5`，那是 MCP 月度） |
| GLM 时间戳 | `nextResetTime` 是**毫秒**时间戳（不是 ISO 8601） |
| MiniMax 模型选择 | 数组里 `model_name="general"` 优先于 `video` |
| GLM 响应位置 | `data.limits`（不是顶层 `limits`） |
| @Published.objectWillChange | 在 `willSet` 触发，值未写入 → 1 帧滞后。用 `$propName` 监听更稳 |
| 配置项必须数据流通 | UI → Binding → Store → 消费方，**任一环节没接通 = 等于不存** |

## 3. 用户当前配置（实测值）

- **3 平台 Key 全部已配置**：Kimi / MiniMax / GLM
- **阈值（用户在设置面板拖过）**：
  - 黄色警告 (warning) = 60%
  - 橙色严重 (critical) = 86%
  - 红色危险 (danger) = 95%
- **实测**：MiniMax 70% → 应显示**黄色**

## 4. 用户偏好

- **中文交流**
- **严禁 Emoji**（全局规则）
- **Markdown 写完自动 Marked 打开**（全局规则）
- **动作导向**：能直接做就不要问
- **配置项 UI 偏好**：slider 拖动 + 数字框直接输入（双向同步）
- **隐私敏感**：Keychain + Touch ID/系统密码验证（bank-level security）

## 5. 已知问题 / 待优化

| 编号 | 内容 | 优先级 |
|------|------|--------|
| KNOWN-1 | GLM 周维度（`TOKENS_LIMIT + unit=6`，32%）暂未展示 | 低 |
| KNOWN-2 | GLM MCP 月度（`TIME_LIMIT + unit=5`，9%）暂未展示 | 低（用户不用关心） |
| KNOWN-3 | v1.0-onboarding-walkthrough.md §3.1 仍写"raw binary 启动"（应该是 .app bundle 启动） | 中 |
| KNOWN-4 | v1.0-test-inventory.md Kimi/MiniMax 部分没更新到 v1.0.1 真实响应格式 | 中 |

## 6. 关键文件路径速查

| 类别 | 路径 |
|------|------|
| 3 平台 Provider | `QuotaMonitor/Services/Networking/{Kimi,MiniMax,GLM}Provider.swift` |
| 并行抓取 | `QuotaMonitor/Services/Networking/NetworkingService.swift` |
| 状态栏 UI | `QuotaMonitor/UI/MenuBar/MenuBarController.swift` |
| 设置面板 | `QuotaMonitor/UI/Settings/SettingsView.swift` |
| 阈值配置存储 | `QuotaMonitor/State/SettingsStore.swift` |
| 应用编排 | `QuotaMonitor/State/AppState.swift` |
| Provider 测试 | `QuotaMonitorTests/{Kimi,MiniMax,GLM}ProviderTests.swift` |
| Networking 测试 | `QuotaMonitorTests/NetworkingServiceTests.swift` |
| 项目根 | `<PROJECT_ROOT>/` |
| 母港 memory | `~/.claude-minimax/.../memory/project-quotamonitor-v101-fix-20260617.md` |
| 母港 memory | `~/.claude-minimax/.../memory/project-quotamonitor-v102-fix-20260617.md` |

## 7. 构建 & 运行命令

```bash
# 构建
cd <PROJECT_ROOT>
swift build -c release

# 测试
swift test --package-path <PROJECT_ROOT>

# 打包 .app（必须，否则 UNUserNotificationCenter 崩溃）
cp .build/release/QuotaMonitor build/QuotaMonitor.app/Contents/MacOS/QuotaMonitor
codesign --force --deep --sign - build/QuotaMonitor.app

# 启动
open build/QuotaMonitor.app
```

## 8. 下次会话预期

- 用户已切换到 QuotaMonitor 项目自己的对话框
- sub-agent 唤醒后第一件事：**读本文件**了解上下文
- 之后正常等待用户提问 / 反馈新 bug
- 如果用户做"~desensitize 扫描"或"~audit 体检"，按 AgentForge 标准流程走

## 9. 用户反馈原文（保留以备查）

- "我字段弄错了。在 GLM 里边，我打开网页看到三个百分比：1. 0% 是我们实际上想要的，是每 5 小时的使用额度；2. 32% 是每周使用的额度；3. 9% 是你提供的那个，但这不符合我的需求，它是 MCP 每月的额度。"
- "我觉得滑块旁边如果能再加入一个数字框，让我可以直接填入数字，可能会更好"
- "我又犯了一个错误。应该在你当前的 AgentForge 项目里面做 build，build 完之后，我应该去当事人自己的项目里运行后面的测试和执行。但目前我们还是在 AgentForge 的对话框里，其实是错的。"

---

**重要：本文件是临时记忆，不是最终交付。**
**唤醒后第一件事是读本文件 + 跑一遍构建测试，验证状态。**
