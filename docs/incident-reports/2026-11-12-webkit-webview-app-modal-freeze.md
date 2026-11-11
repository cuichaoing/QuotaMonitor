# 网页型平台三连坑：离屏窗口不渲染 / cookie 不落盘 / 钥匙串弹窗冻结整个 App

> 报告日期：2026-11-12
> 编号：BUG-2026-11-11-05 / BUG-2026-11-11-03 / BUG-2026-11-12-01
> appVersion：1.3.0
> 阶段：完成（代码已修复 + 回归测试 + 实机验证）
> 背景：为接入百度千帆（网页会话型）而排查

---

## 0. 结论摘要

三个互相独立、但**症状都表现为「抓不到数据」**的坑，叠加后极难定位：

| # | 坑 | 表现 | 根因 | 修法 |
|---|---|---|---|---|
| 1 | 离屏窗口不渲染 SPA | `innerText` 只剩 165 字符骨架 | **macOS 不合成屏幕外窗口** → WebKit 不渲染 | 完整尺寸窗口 + **位置**挪到屏幕右缘外 |
| 2 | cookie 不落盘 | 每次重启都要重新登录（用户输了 4~5 遍密码） | 非沙盒 App 的 WebKit **不持久化 cookie** | 自己导出/恢复 cookie |
| 3 | 钥匙串弹窗冻结整个 App | 弹窗点不动，且 App 停止一切刷新 | 钥匙串授权框是 **app-modal** → MainActor 挂起 | 抓取页屏蔽 password input |

---

## 1. 坑 1：离屏窗口不渲染 SPA

### 现象

隐藏抓取 WebView 挂在 `(-2000,-2000)` 的窗口上（沿用 Gemini 的写法），
页面能加载（URL 对、title 对），但 `document.body.innerText` 恒为 165 字符——
只有导航骨架，提取脚本永远拿不到数字。

### 定位：对照实验

写了个独立探针程序，注入同一份 cookie，用同一套 WKWebView 只换窗口位置：

| 窗口位置 | innerText 长度 | 能否抓到 |
|---|---|---|
| 屏幕外 `(-2000,-2000)` | **165**（骨架） | 否 |
| 屏幕内（各种位置/alpha/层级） | **1541**（完整内容） | **是** |

### 根因

**macOS 不合成屏幕外的窗口**，WebKit 因此不渲染单页应用。
另外注意 **`NSWindow.contentView` 会裁剪子视图** —— 窗口只有 2×2 时，
即使 `webView.frame` 是 480×360，实际可见区域仍被裁到 2×2 → 同样不渲染。
（这一条把我自己坑了一次：改了 webView 尺寸却忘了改窗口 contentRect。）

### 修法

```swift
let screen = NSScreen.main?.visibleFrame
let window = NSWindow(
    contentRect: NSRect(x: screen.maxX - 2, y: screen.minY, width: 480, height: 360),
    styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = webView        // webView.frame 与窗口一致
window.alphaValue = 0.02
window.ignoresMouseEvents = true     // 不吃鼠标事件
window.orderBack(nil)                // 只把「位置」挪出屏，屏幕内仅露 2px
```

**alpha（0.02/0.5/1.0）、窗口样式（borderless/titled）、层级（normal/floating）全都无关**，
别在这些维度上瞎试。唯一要保证的两条：**contentView 尺寸 ≥ webView 尺寸** + **窗口在屏幕内**。

### 附带发现：同进程多个 WKWebView 会互相干扰

同一进程里先后创建多个 WebView 加载重 SPA 时，后一个可能一直停在骨架。
→ 登录成功后把登录页 `load(about:blank)` 卸载；抓取时检测「渲染停滞」（innerText 连续 2 秒不变）并自动 reload。

---

## 2. 坑 2：cookie 不落盘

### 现象

用户反复被要求登录百度（输了 4~5 遍密码），每次重启 App 都重来。

### 根因

macOS 上**非沙盒** App 的 WKWebView 不持久化 cookie：

```
~/Library/WebKit/app.quotamonitor/WebsiteData/Default/Cookies   → 0 字节（empty）
~/Library/Cookies/                                            → 空
localStorage                                                  → 空
```

（Gemini 同样如此，只是一直没人把 App 重启到能察觉。）

### 修法

不依赖 WebKit 的磁盘策略，自己来：

- 登录/抓取成功后：`httpCookieStore.getAllCookies` → 只留目标域 → 导出 JSON 到
  `~/Library/Application Support/QuotaMonitor/baidu_cookies.json`
- 每次 `fetchQuota()` 前：读回 → `setCookie` 灌回（幂等）
- 「退出登录」时一并删除该文件

恢复时只还原必要字段（name/value/domain/path/secure/expires），
**不要直接序列化 `HTTPCookie.properties`**（`expiresDate` 是 Date，过不了 JSON）。

---

## 3. 坑 3：钥匙串弹窗冻结整个 App（最隐蔽）

### 现象

用户看到一个「输入密码 / 始终允许」的弹窗，**点不下去**，一直挂在那里；
同时 App 状态栏图标消失（crash）。

### 根因链（两层）

**第一层：WebKit 密码自动填充**
抓取页面里存在 `<input type=password>`（控制台即使已登录，DOM 里仍可能残留隐藏登录框），
WebKit 因此去访问 macOS 钥匙串，弹出 `SecurityAgent` 授权框（434×182 的独立窗口）。

**第二层（真正致命的）：该框是 app-modal**
弹出后 App 进入 modal session → **MainActor 被挂起** → 所有 `@MainActor` 工作排队等待，
包括 `refresh()`。于是「App 开着但一个平台都不更新」。

**证据**：杀掉弹窗的瞬间，cookie 文件的 mtime 立刻跳动（06:53:19）——App 瞬间恢复抓取。
反过来观察：弹窗存在期间 App 进程 CPU 只有 0.1%、抓取 WebView 窗口根本没被创建。

### 修法

抓取 WebView 注入脚本，把页面里的 password input 全部改成 `text`：

```js
document.querySelectorAll('input[type="password"]').forEach(el => {
  el.setAttribute('type', 'text');
  el.removeAttribute('autocomplete');
});
```
配合 `MutationObserver` 在 DOM 变化时重复执行。

第二层保险：在 **Info.plist 的 `NSUserDefaults` 字典**里禁
`WebKitPasswordAutosaveEnabled` / `WebKitPasswordAutoFillEnabled`。
（注意：写进 `UserDefaults.standard.set` **无效**——WebKit 不读 app 域，只读 app 自己声明的默认项。）

---

## 4. 教训

1. **「取到非 nil 就当成功」是这类 bug 的共同放大器**。判定成功要卡**具体证据**
   （渲染出用量、确切时刻），而不是「有值」。
2. **网页型平台的失败模式往往不是「解析失败」，而是「页面根本没渲染」**——
   排查第一步应该是打印 `innerText` 长度，而不是盯着选择器。
3. **对照实验 + 独立进程**是定位这类问题的最快手段。同一进程连做多组配置会互相干扰，
   导致结论自相矛盾（本次矩阵测试就出现过同一配置两次结论相反）。
4. **任何 app-modal 系统弹窗都可能冻结整个 App**。macOS 上这类弹窗的归属窗口若不可见，
   用户根本点不掉 —— 这是「App 卡住」类报错的排查方向之一。
