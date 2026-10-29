# Gemini 网页订阅配额监控接入 — 技术笔记

> 日期：2026-10-29
> 版本：v1.1.0 引入
> 代码：`QuotaMonitor/Services/WebSession/{GeminiSessionManager,GeminiUsageParser}.swift`
> 探针：`scripts/gemini_login_probe.swift`（选型验证用，可复现）

---

## 0. 为什么需要一条新链路

前三个平台（Kimi / MiniMax / 智谱 GLM）都是 **API Key 型**：Key 存 Keychain，
定时打官方 API，拿 JSON 解析。Gemini 订阅配额**没有 API**——只在登录后的网页
`gemini.google.com/usage` 上以人类可读形式呈现。这决定了整条链路的形态：

| 维度 | API Key 型（K/M/G） | 网页会话型（Gemini） |
|------|-------------------|-------------------|
| 鉴权 | Keychain 存 Key | 用户在 App 内登录 Google，cookie 存 WebKit 存储 |
| 取数 | URLSession 打 API | WKWebView 加载页面 + 注入 JS 读 DOM |
| 刷新 | 30s–5m 智能节流 | 独立 5 分钟下限（页面重，别高频打） |
| 过期 | 401 → 提示配 Key | cookie 失效 → 引导重新登录 |
| 错误 | `keyMissing/keyInvalid` | `sessionMissing/sessionExpired` |

---

## 1. 选型：A（内嵌 WKWebView） vs B（专用 Chrome + CDP）

AgentForge 情报：舰队里已有成熟方案——**专用 Chrome + CDP 接管**
（`GeminiExporter`，独立 profile + `--remote-debugging-port`，抓 gemini.google.com 两个月未掉登录）。
但**没有先例**在 App 内嵌 WKWebView 登 Google。

于是先做探针（`scripts/gemini_login_probe.swift`）验证 A，失败就落 B。

### 探针结论：A 可行

| 尝试 | 结果 |
|------|------|
| 伪装 **Chrome UA** | ❌ Google 报「此浏览器或应用不安全」 |
| 伪装 **本机真 Safari UA** | ✅ 登录完整走通（含两步验证 challenge） |

**为什么 Chrome UA 不行**：WKWebView 的 JS 环境里没有 `window.chrome`、也不发 Chrome 的
client-hints，UA 说自己是 Chrome、特征却不是 Chrome —— 自相矛盾。
**为什么 Safari UA 行**：WKWebView 本就是 WebKit + Apple 网络/TLS 栈，
与真 Safari 同引擎同 TLS 特征，UA 与实际能力自洽。

本机 UA（Safari 26.6.2）：

```
Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.6.2 Safari/605.1.15
```

---

## 2. 六个必踩的坑

### 坑 1：登录判据必须是认证 cookie，不是域名

登录墙页面**本身就在 `gemini.google.com` 域上**（未登录时 `/usage` 被 JS 软跳到 `/app`，
HTTP 200，不跳 `accounts.google.com`）。只看域名会把"停在登录墙"误判成"登录成功"。

判据用 cookie store 里的 `SID / SSID / HSID / SAPISID / APISID`（HttpOnly，JS 读不到）：

```swift
private func hasGoogleAuthCookies() async -> Bool {
    let cookies = await withCheckedContinuation { cont in
        dataStore.httpCookieStore.getAllCookies { cont.resume(returning: $0) }
    }
    return cookies.contains {
        ["SID","SSID","HSID","APISID","SAPISID"].contains($0.name) && $0.domain.contains("google.com")
    }
}
```

### 坑 2：数据不在初始 HTML，必须等 DOM 渲染

Gemini 是 React SPA。`curl` 未登录页只能拿到 1.3MB 引导页，**一个用量数字都没有**。

好消息是 Google 留了自家测试锚点 `data-testid`（比 utility class 稳得多）：

```html
<li data-testid="current-usage">
  <strong>当前用量</strong>
  <strong>已使用 31%</strong>
  <span>重置时间：13:01</span>
</li>
<li data-testid="weekly-usage">
  <strong>每周限额</strong>
  <span>重置时间：11月2日16:01</span>
  <strong>已使用 3%</strong>
</li>
```

抓取策略：**轮询等元素出现**（不固定 sleep）→ 出现后只取这两个 `<li>` 的 `outerHTML` →
`GeminiUsageParser` 解析 → 立刻 `about:blank` 卸载页面（否则 WebContent 常驻 ~400MB）。

### 坑 3：提取要有候选链（防改版 / 防语言）

1. `data-testid` 块内「已使用 X%」文本
2. 兜底：进度条内联样式 `--x-width: 31%`（**语言无关**，英文 UI 也适用）
3. 兜底：`Used 31%`（英文 UI 变体）

重置时间两种格式都要解析：`13:01`（当天或次日）、`11月2日16:01`（月日+时刻，无年份，
跨年回退）。

### 坑 4：NSWindow 关闭时序会崩（实测踩到）

v1.1.0 首启登录成功后崩溃：

```
-[_NSWindowTransformAnimation dealloc] → objc_release 过度释放
```

两个触发点，**两个都得堵**：

1. `windowWillClose` 里立刻 `loginWindow = nil` → 窗口在关闭动画未结束时被释放
   → 改为 `asyncAfter(0.5s)` 再释放
2. 登录流程连续触发多次 `didFinish`（`/app` → ogs widget → …），每次都排一个 Task 关窗
   → **同一窗口被关两次** → 加 `loginAutoCloseScheduled` 去重标志；
   并在关窗前 `webView.stopLoading()`（关窗时仍在导航会踩 AppKit 释放时序）

### 坑 5：别让 WebKit 对象进非主线程

`GeminiSessionManager.shared` 的 `init` **绝不能碰 WebKit**（`WKWebsiteDataStore.default()`）。
否则任何测试线程经默认参数链触发它时，WebKit 主线程断言会异步崩掉整个测试进程
（表现：某个无关的测试类中途 signal 5，极难定位）。cookie 仓改 `lazy var`。

### 坑 6：给网页抓取单独限频

Gemini 页面加载是 MB 级 + JS 渲染，不能跟 API 平台共享 30s 智能节流。
`GeminiSessionManager.minFetchInterval = 300`（5 分钟），实测抓取时刻稳定落在
`13:30:01 / 13:35:05`，中间 5 分钟内其他平台轮询 10 轮、Google 零请求。

---

## 3. 数据模型映射

| 页面 | 模型 | 展示 |
|------|------|------|
| `current-usage`（已使用 31%，重置 13:01） | `primaryWindow`（`total=100, used=percent`） | 状态栏主数字 + 倒计时 |
| `weekly-usage`（已使用 3%，重置 11月2日16:01） | `weeklyWindow` | Popup 副行「7d」 |

`total=100 / used=percent` 的百分比技巧沿用 GLM 方案（服务端只给百分比时约定）。

---

## 4. 会话状态机

```
notLoggedIn ──登录成功(cookie 出现)──> loggedIn
loggedIn ──抓取时被弹回 accounts.google.com──> expired ──重新登录──> loggedIn
expired ──抓取成功(Google 侧自愈)──> loggedIn
```

- `expired` 会发系统通知（每小时最多一条），引导去设置页重登
- `QuotaError.sessionMissing / .sessionExpired` 均 `isUserActionable = true`

---

## 5. 验证方法（可复现）

```bash
# 1. 选型探针：验证能否在 WKWebView 内登录 + 抓 DOM
cd scripts && swift gemini_login_probe.swift
#   → 登录成功后自动落盘 /tmp/gemini_usage_dom.html（含真实用量块）

# 2. 真实 DOM 做解析器夹具（测试里已固化）
#    QuotaMonitorTests/GeminiUsageParserTests.swift

# 3. 限频验证：按响应体大小区分页面加载 vs API 调用
log show --last 10m --info --debug --style compact \
  --predicate 'eventMessage CONTAINS "response_bytes"' | grep -E 'response_bytes=[0-9]+'
```

---

## 6. 给后来者的建议

1. **先探针再实现** —— A/B 两条路的差别是"登录能不能过"，花 20 分钟写探针，
   比写完 800 行再发现走不通便宜得多。探针脚本留在 `scripts/` 里可复现。
2. **抓真实响应再写代码**（CONTRIBUTING「必读陷阱」第 1 条）：
   MiniMax 那次 bug 就是没抓真实字段、猜了个 `interval_end_time` 猜了 4 个月。
3. **登录类需求先问"怎么证明登录了"** —— 本次的核心教训。
   「落在目标域名上」不构成登录证据；cookie 才是。
