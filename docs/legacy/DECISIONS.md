# 1.x QuotaCat → 2.0 QuotaMonitor 决策追溯

> 本文档记录从历史项目 `2026.1.29-智谱配额监控插件`（QuotaCat v1.0.12，最终迭代 2026-02-14）演进到 QuotaMonitor v2.0 的全部设计决策。
> 目的：保留决策痕迹，避免重复试错；为后续维护者提供"为什么这样做"的完整上下文。

---

## 1. 1.x 真实形态快照

| 维度 | QuotaCat 1.0.12 现状 |
|------|---------------------|
| 架构 | Python 独立进程 + Swift 前端，JSON 文件 IPC（`quota_data.json`） |
| 数据源 | Playwright 抓 `bigmodel.cn/usercenter/glm-coding/usage` 页面 |
| 鉴权 | 浏览器会话持久化到 `session_state.json`（Cookie JSON） |
| 监控范围 | 单平台（智谱 GLM） |
| 刷新策略 | 固定 60s 间隔 |
| 颜色阈值 | 绿 / 黄 / 橙 / 红（对应 80% / 50% / 30% / 10% 已用） |
| 进程模型 | `threading.Thread` + `threading.Event` 信号驱动 |
| 数据目录 | `~/Library/Application Support/QuotaCat/` |
| 写入策略 | temp 文件 + atomic rename 防半写 |
| 终止时间 | 2026-02-14（停止维护，4 个月未动） |

---

## 2. 7 项吸收（直接复用 1.x 设计）

| # | 设计点 | 1.x 落地形式 | 2.0 复用方案 |
|---|--------|-------------|--------------|
| 1 | **CLI 参数化** | `--interval / --no-headless / --force-login / --debug` | 映射到 SwiftUI SettingsView 可调项（节流间隔、登录重置、调试模式） |
| 2 | **原子写入** | `temp_file.replace(target)` | 历史快照 SQLite 用 `BEGIN IMMEDIATE` 事务；JSON 缓存用 `Data.write(.atomic)` |
| 3 | **数据目录规范** | `~/Library/Application Support/{name}/` | 直接沿用：`~/Library/Application Support/QuotaMonitor/` |
| 4 | **4 级颜色阈值** | 绿/黄/橙/红 | 改为 75/90/99 三级业务阈值 + 4 级图标集（normal/warning/critical/error） |
| 5 | **CHANGELOG 规范** | SemVer + feat/fix/refactor 分类 | 沿用，每月打 tag |
| 6 | **开发日志按日期+阶段** | `2026-01-29-mvp-phase1.md` | 沿用，每完成一阶段落盘一份 |
| 7 | **统一信号处理** | `main.py` 集中处理 SIGINT/SIGTERM | Swift 端对应 `applicationWillTerminate` + 状态机优雅停机 |

---

## 3. 8 项反模式（1.x 教训，2.0 必须绕开）

| # | 反模式 | 1.x 做法 | 2.0 替换 | 理由 |
|---|--------|---------|----------|------|
| 1 | **Playwright 抓 DOM** | 每平台启 Chromium，120s 登录 | `URLSession` 直击官方 API | 内存爆炸（50-150MB/平台）+ 反爬 + DOM 脆弱 |
| 2 | **Cookie 持久化** | `session_state.json` 存 Cookie | Keychain 存 API Key | OS 硬件级加密 + 设备绑定 |
| 3 | **固定刷新间隔** | 60s 雷打不动 | 30s / 1m / 5m / 暂停 四级智能节流 | 空闲期省电，活跃期实时 |
| 4 | **字符串百分比** | JSON 存 `"75%"` | `ProviderQuota.usedPercent: Double` | 结构化数据便于 UI/分析/历史 |
| 5 | **多进程 + 文件 IPC** | Python 进程 + Swift FileWatcher | 纯 Swift `actor NetworkingService` + Combine 流式推送 | 实时性 + 无序列化开销 |
| 6 | **DOM 选择器硬编码** | `.percentage-value` 写死 | 走官方 `api.z.ai/api/monitor/usage/quota/limit` | 选官方 API，零脆弱性 |
| 7 | **同步 API** | `sync_playwright` 阻塞 | 全 `async/await` + `withTaskGroup` 并行 | 不阻塞主线程，3 平台并发 |
| 8 | **阻塞式 DOM 提取** | `inner_text()` 阻塞 5s 超时 | URLSession 200ms 内完成 | 性能差距两个数量级 |

---

## 4. 阈值演进（80/50/30/10 → 75/90/99）

### 1.x 阈值（基于 DOM 抓取的"剩余量"反向解读）

```
  80% 剩余  -> 绿  (安全)
  50% 剩余  -> 黄  (警告)
  30% 剩余  -> 橙  (严重)
  10% 剩余  -> 红  (阻断)
```

### 2.0 阈值（基于"已用百分比"的业界标准）

```
  75% 已用  -> 黄  (准备切换模型)
  90% 已用  -> 橙  (停止大额并发)
  99% 已用  -> 红  (阻断前兆)
```

### 演进理由

- 1.x 阈值是抓"剩余量"反推的，1.x 用户的实际感受是"还有 50% → 黄灯"——心智模型反直觉
- 2.0 阈值是直观的"已用"——75% 用了 → 黄灯，符合 Windows/macOS 资源监控器的语义
- 阈值提升至 90/99 是因为大模型 Coding Plan 的"完全耗尽"通常意味着缓存命中率归零，体感比 50% 更剧烈

### 实现细节

```swift
// 1.x -> 2.0 阈值映射代码（不要在新代码里用，仅作决策档案）
// let warningThreshold = 20   // 1.x：剩余 20% 触发黄灯
// let criticalThreshold = 10  // 1.x：剩余 10% 触发橙灯
// newThreshold 改为（已用百分比）
// 75% 触发黄灯
// 90% 触发橙灯
// 99% 触发红灯
```

---

## 5. 域名迁移（bigmodel.cn → api.z.ai）

### 1.x 配置

```python
# backend/config.py (1.0.12)
BIGMODEL_HOME_URL = "https://bigmodel.cn"
BIGMODEL_QUOTA_URL = "https://bigmodel.cn/usercenter/glm-coding/usage"
```

### 2.0 端点

```swift
// 智谱 GLM 监控新端点
let url = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
```

### 迁移理由

- `bigmodel.cn` 旧域保留 Web 控制台，但 API 已迁移至 `api.z.ai`（智谱官方调整）
- 旧端点 `usercenter/glm-coding/usage` 已不再返回 JSON 配额数据，需用户登录 session 才能解析 DOM
- 新端点 `/api/monitor/usage/quota/limit` 无需 session，直接 API Key 鉴权，更稳定

### 警告

- 任何新代码**禁止**用 `bigmodel.cn` 作为 API 端点
- 2.0 直接锁 `api.z.ai`，不留 fallback（避免静默走老路径）

---

## 6. 协议层设计（2.0 新增）

1.x 没有任何协议抽象——`scraper.py` 是一个 200 行的过程式函数，绑死智谱。

2.0 引入两个核心协议：

```swift
public protocol Provider: Sendable {
    var kind: ProviderKind { get }
    func fetchQuota(apiKey: String, using client: HTTPClient) async throws -> ProviderQuota
}

public protocol KeychainStoreType: Sendable {
    func save(_ value: String, for provider: ProviderKind) throws
    func read(for provider: ProviderKind) throws -> String?
    func delete(for provider: ProviderKind) throws
}
```

设计要点：

- **Provider 协议不持有 HTTPClient**：通过方法参数注入，便于 mock 测试
- **ProviderQuota 统一结构**：所有平台返回相同结构（`primaryWindow: QuotaWindow?`），UI 层零分支
- **KeychainStoreType 协议化**：可注入内存 mock（测试用），生产用 `KeychainStore`

---

## 7. 数据平滑算法（2.0 新增，对治 MiniMax 被动流失）

### 问题

MiniMax 的 `remains_time` 字段在无 API 调用时也会"被动流失"——表现为 used 数值微小跳变。

### 2.0 解法

```swift
// NetworkingService.applySmoothing()
guard let prev = lastSnapshot[kind],
      let prevWin = prev.primaryWindow,
      let curWin = quota.primaryWindow,
      prev.windowFingerprint == quota.windowFingerprint else {
    return quota  // 新窗口或首次，无需平滑
}

if curWin.used < prevWin.used {
    // 倒退：保留上一次（被动流失后回弹）
    return ProviderQuota(...)
}
return quota
```

### 关键

- 窗口指纹 = `floor(epoch / 18000)`（每 5h 一个 ID）
- 只在同窗口内做平滑，跨窗口不沿用
- 平滑后的数据才进入 UI 和历史存储

---

## 8. 项目登记建议

QuotaMonitor 2.0 不在 AgentForge True MAS 模板范畴（无 Python Agent、无 EventBus / StateManager），但仍可登记为 `standalone-macos-app` 派生项目。登记字段建议：

```json
{
  "name": "QuotaMonitor",
  "path": "<PROJECT_ROOT>",
  "status": "active",
  "architecture": "standalone-macos-app",
  "tech_stack": ["Swift 5.0+", "SwiftUI", "AppKit", "URLSession", "Keychain"],
  "monitor_targets": ["Kimi", "MiniMax", "GLM"],
  "agents": [],
  "forge_method": "manual",
  "forge_date": "2026-06-17",
  "parent_template": "opencode-bar (opgginc) + Usage4Claude 调研成果",
  "note": "AgentForge 独立项目（非 Agent），吸收 1.x QuotaCat 决策"
}
```

---

## 9. 版本历史

| 版本 | 日期 | 关键变更 |
|------|------|----------|
| 2.0 (v0.1) | 2026-06-17 | 核心服务层（Provider / Keychain / NetworkingService / SmartRefreshScheduler）落盘 |
| 1.0.12 | 2026-02-14 | 1.x 最后一个版本（仅 GLM 单平台、Playwright 抓 DOM） |
| 1.0.0 | 2026-02-09 | 1.x 初始版本（Python + Playwright + rumps） |

---

## 10. 维护者备忘

- 新增平台：实现 `Provider` 协议 + `ProviderKind` 枚举 + 颜色 token
- 修改阈值：改 `AlertStateMachine`（P1 待实现），不要动 `ProviderQuota`
- 老用户迁移：QuotaCat 1.x 的 `~/Library/Application Support/QuotaCat/session_state.json` **不可直接迁移**到 2.0（Cookie → API Key 范式转换），需要用户重新输入 API Key
- 反爬绕过：如某平台 1.x 的 Playwright 抓取仍有效，可以作为 2.0 启动初期的"备选数据源"，但**不是长期方案**

---

*由 AgentForge 主控 + QuotaMonitor 联合沉淀*
*最后更新：2026-06-17*
