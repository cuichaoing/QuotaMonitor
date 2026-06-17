# QuotaMonitor - 项目主控指令

> 版本：v1.0.2（2026-06-17）
> 角色：QuotaMonitor sub-agent 主控路由 + 唤醒词

---

## [强制前置读取] 唤醒协议

**你刚刚被唤醒。** 在开口回答任何问题之前，**先静默**读取以下文件：

1. `docs/HANDOFF_v1.0.2_2026-06-17.md` —— 完整业务上下文（修复历史 / 技术陷阱 / 用户配置 / 构建命令），**必读**
2. `CHANGELOG.md` —— 版本变更记录
3. `README.md` —— 项目入口
4. `USER_GUIDE.md` —— 用户使用手册

读完后才能开始回答用户。

---

## [当前状态快照]

| 项目 | 状态 |
|------|------|
| 版本 | v1.0.2 |
| 测试 | 105/105 全过（`swift test`，~0.5s） |
| 部署 | `build/QuotaMonitor.app` ad-hoc 签名完成 |
| 平台 | Kimi / MiniMax / GLM 全部 fetch 成功，无 `diag.txt` 错误 |

---

## [本会话关键变更]

### v1.0 → v1.0.1：3 平台 Provider 按真实 API 重写
- **Kimi**：`limits[0].detail.{limit, used, resetTime}` 嵌套结构（值是字符串）
- **MiniMax**：`current_interval_remaining_percent` 反算 usedPercent，`model_name="general"` 优先
- **GLM**：`data.limits[i].percentage` 直接给百分比（**data 不是顶层**）

### v1.0.1 → v1.0.2：UI 修复
- **阈值 slider 颜色失效**：`MenuBarController.nsColor(for:)` 改读 `SettingsStore`，`observeState()` 用 `Publishers.Merge3` 监听 3 个 `$publisher`（避免 `objectWillChange` 1 帧滞后）
- **ThresholdSlider 加可编辑 TextField**：slider 拖动 + 数字框输入双向同步

---

## [用户实测配置]

- **3 平台 Key 全部已配置**：Kimi / MiniMax / GLM
- **阈值**（用户在设置面板拖过）：
  - 黄色警告 (warning) = **60%**
  - 橙色严重 (critical) = **86%**
  - 红色危险 (danger) = **95%**
- **实测**：MiniMax 70% → 应显示**黄色**

---

## [全局偏好]

- **中文交流**
- **严禁 Emoji**（用 [OK] [X] [!] [>] 等文字符号代替）
- **写完 .md 立即 `open -a Marked`**（README / CHANGELOG 例外）
- **动作导向**：能直接做就不要问
- **隐私敏感**：API Key 走 Keychain + 显示需 Touch ID / 系统密码验证

---

## [必记陷阱]

| 陷阱 | 说明 |
|------|------|
| GLM 5h 配额识别 | `TOKENS_LIMIT + unit=3`（**不是** `TIME_LIMIT + unit=5`，那是 MCP 月度） |
| GLM 鉴权 | Authorization 头**禁止** "Bearer " 前缀，裸 Token 直接传 |
| GLM 时间戳 | `nextResetTime` 是**毫秒**时间戳（不是 ISO 8601） |
| Kimi User-Agent | 必须 `KimiCLI/1.30.0` 才命中 Coding Plan 专属额度 |
| MiniMax 模型选择 | 数组里 `model_name="general"` 优先于 `video` |
| GLM 响应位置 | `data.limits`（不是顶层 `limits`） |
| `@Published.objectWillChange` 时序 | 在 `willSet` 触发，值未写入 → 1 帧滞后。用 `$propName` 监听更稳 |
| 配置项数据流通 | UI → Binding → Store → 消费方，**任一环节没接通 = 等于不存** |

---

## [构建 & 运行]

```bash
cd <PROJECT_ROOT>

# 构建
swift build -c release

# 测试
swift test --package-path .

# 打包 .app（必须，否则 UNUserNotificationCenter 崩溃）
cp .build/release/QuotaMonitor build/QuotaMonitor.app/Contents/MacOS/QuotaMonitor
codesign --force --deep --sign - build/QuotaMonitor.app

# 启动
open build/QuotaMonitor.app
```

---

## [关键文件路径速查]

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
| 会话交接 | `docs/HANDOFF_v1.0.2_2026-06-17.md` |

---

## [已知问题]

| 编号 | 内容 | 优先级 |
|------|------|--------|
| KNOWN-1 | GLM 周维度（`TOKENS_LIMIT + unit=6`）暂未展示 | 低 |
| KNOWN-2 | GLM MCP 月度（`TIME_LIMIT + unit=5`）暂未展示 | 低（用户不用关心） |
| KNOWN-3 | `docs/v1.0-onboarding-walkthrough.md` §3.1 仍写"raw binary 启动" | 中 |
| KNOWN-4 | `docs/v1.0-test-inventory.md` Kimi/MiniMax 部分没更新到 v1.0.1 真实响应格式 | 中 |

---

**等待用户提问或反馈新 bug。**
