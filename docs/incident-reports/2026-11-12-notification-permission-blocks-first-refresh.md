# 通知权限请求挡在首次刷新前 — App 启动后一个平台都不抓

> 报告日期：2026-11-12
> 编号：BUG-2026-11-12-02
> appVersion：1.3.0
> 阶段：完成（代码已修复 + 实机验证）
> 严重度：**高**（用户表现为「App 启动了但什么都没抓到」，且无任何报错）

---

## 0. 结论摘要

| 维度 | 结论 |
|------|------|
| 性质 | **任何可能等待用户交互的 `await` 挡在「干活」前面** |
| 现象 | App 进程活着、状态栏图标在，但所有平台都没数据，抓取 WebView 都没被创建 |
| 根因 | `bootstrap()` 里 `await notifications.requestPermission()` 排在 `await refresh()` 之前，而它在用户未决定时**永不返回** |
| 修复 | 权限请求挪进独立 Task，不阻塞刷新 |
| 通用性 | 与通知无关 —— 任何 `requestPermission` / 弹窗 / `open` 类 await 都属这一类 |

---

## 1. 现象

排查千帆「一直感叹号」时，App 已运行 3 分钟，但：

- 所有平台的抓取 WebView 窗口**一个都没被创建**（窗口列表里只有设置窗口）
- 进程 CPU **0.1%**（完全空闲，不像在抓）
- 状态相关的 cookie 文件 mtime 一直不更新

乍看像「抓取没被触发」，但调度器 `runLoop()` 启动时明明会立即 `await onTick?()`。

---

## 2. 根因

```swift
// AppState.bootstrap()
Task {
    _ = await notifications.requestPermission()   // ← 用户不点系统弹窗就永远不返回
    await refresh()                                // ← 永远执行不到
}
```

`UNUserNotificationCenter.requestAuthorization(options:)` 在用户**未决定**（`notDetermined`）时
会显示系统弹窗并**挂起 await 直到用户选择**。用户没看到、没点、或者弹窗被别的窗口挡住，
这个 await 就永不返回 → **首次 refresh 被饿死**。

表现极具迷惑性：进程活着、UI 正常、但一个平台都不抓，而且**没有任何错误日志**。

---

## 3. 修复

```swift
Task {
    Task { _ = await notifications.requestPermission() }   // 不阻塞
    await refresh()
}
```

---

## 4. 为什么值得单独记一篇

这类 bug 的特征是「**没有任何报错**」——因为它不是失败，是**根本没开始**。
排查时容易误判成「网络问题」「WebView 渲染问题」「解析问题」，
从而在错误的方向上花掉大量时间（本例中我先后怀疑了离屏渲染、cookie、解析正则）。

**判据**：如果「某个动作从未发生」（而非「发生了但结果不对」），
优先查**前置 await 是否挂起**，而不是查那个动作本身。

同类需要警惕的 API：`UNUserNotificationCenter.requestAuthorization`、
`NSOpenPanel.runModal`、各类 `alert.runModal`、需要用户在系统弹窗上确认的
`SMAppService.register()` 相关流程、以及任何 `await` 了「等待用户输入」的桥接方法。

---

## 5. 验证

- 修复后新进程启动，**无需任何用户干预**即在 30 秒内完成一轮全平台抓取
  （cookie 文件 mtime 同步跳动）
- 179/179 测试通过
