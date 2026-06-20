# Pop 菜单 vs 状态栏 稳定数字分裂 — 根因 + 修复

> 报告日期：2026-06-20
> 编号：BUG-2026-06-20-01
> appVersion：1.0.10 → 修复 v1.0.12
> 阶段：完成（代码已 commit + push）
> 处理流程：bug 反馈 2 阶段 HITL（本工单节点 2 已确认）

---

## 0. 结论摘要

**Bug 属实，根因单一，已修复。**

| 维度 | 结论 |
|------|------|
| 性质 | Pop 菜单不响应 `store.snapshots` 变化（订阅链路漏配） |
| 现象 | 状态栏持续更新到最新值；Pop 卡片数字停在用户**打开 Popup 那一刻** |
| 触发 | 用户打开 Pop 后，store 因后台 refresh（默认 ~30~60s/次）持续更新；状态栏正确响应，Pop 不响应 |
| 修复 | `PopupView` 内部把 `appState.store` 单独提取成 `@ObservedObject private var store: QuotaStore`，body 内统一改用 `store.xxx` |
| 版本 | v1.0.11 → **v1.0.12** |

---

## 1. 现象（用户实测）

用户反馈：

> 状态栏显示 `0、20、15`，Pop 菜单显示 `0、18、11`。

按 sortOrder（K→M→G）：
- K = 0（Kimi，两侧一致）
- M 状态栏 20 / Pop 18
- G 状态栏 15 / Pop 11

**特征**：Pop 数字是 02:45:25 那次刷新的快照（与诊断 JSON `snapshots.minimax.usedPercent=18, glm.usedPercent=11` 完全一致），状态栏 20/15 是后续被刷新 N 次的更新值。

用户同时报告"刷新多次 Pop 都不更新"——这是关键线索：Pop 视图的 SwiftUI 重算根本没被触发。

---

## 2. 根因（订阅链路漏配）

### 2.1 Pop 视图的订阅关系

`QuotaMonitor/UI/Popup/PopupView.swift` 修复前：

```swift
public struct PopupView: View {
    @ObservedObject public var appState: AppState      // 只订阅 appState.objectWillChange
    @State private var diagFeedback: String?
    ...
    public var body: some View {
        ...
        ProviderCardView(
            kind: kind,
            quota: appState.store.snapshots[kind],     // 读 store.snapshots
            error: appState.store.errors[kind]
        )
        ...
    }
}
```

### 2.2 关键事实：`AppState.store` 不是 `@Published`

`QuotaMonitor/State/AppState.swift:18`：

```swift
@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()
    public let store = QuotaStore.shared               // <-- `let` 属性，不是 @Published
    ...
}
```

`store` 是普通 `let` 属性，**不是** `@Published`。这意味着：

- `store.snapshots`（`@Published`）变化 → 触发 `store.objectWillChange`
- `store.objectWillChange` **不会冒泡**到 `appState.objectWillChange`（因为 `store` 在 AppState 上不是 `@Published`）
- `PopupView` 的 `@ObservedObject var appState: AppState` 只订阅 `appState.objectWillChange`
- → `PopupView.body` 不会被 `store.snapshots` 变化触发

### 2.3 状态栏为什么正常

`QuotaMonitor/UI/MenuBar/MenuBarController.swift:101-112`（v1.0.6 修复后）：

```swift
private func observeState() {
    // [关键 v1.0.6] 用 $snapshots 而不是 objectWillChange
    appState.store.$snapshots                    // <-- 直接订阅 store 的 @Published
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshStatusItemTitle()
        }
        .store(in: &cancellables)
}
```

状态栏用 `appState.store.$snapshots` **直接订阅 store 的 @Published publisher**，绕开了 AppState 这层。所以状态栏会响应 `store.snapshots` 变化，**v1.0.6 的修复是正确的，但只修了状态栏这一处，PopupView 仍然停在错误的订阅上**。

### 2.4 为什么 macOS 13 不会自动追踪

macOS 13（SwiftUI 5.x）不支持 iOS 17+ 的 `@Observable` 宏和 `withObservationTracking`。`@ObservedObject` 的内部实现只订阅**指定的一个** ObservableObject 的 objectWillChange，**不会**自动追踪 body 内访问到的间接 ObservableObject。

所以即使 body 内访问了 `appState.store.snapshots`，SwiftUI runtime 不会自动订阅 `store.objectWillChange`。

### 2.5 SwiftUI 何时重算 PopupView body

PopupView body 在以下时机被求值：
1. NSPopover 首次显示时（构造 rootView + 第一次渲染）
2. 用户点击 Popup 内的"诊断"按钮 → 触发 `appState.exportDiagnostics()` + `@State var diagFeedback` 变化
3. 用户手动点击 Popup 内的"刷新"按钮 → 触发 `appState.refresh()`，但**不**触发 `appState.objectWillChange`，body 也不重算（但 `store.isRefreshing` 临时为 true，刷新完后变 false——这个变化 store 会发 objectWillChange，但 PopupView 没订阅 store）

**结论**：用户每次打开 Pop 看到的是该次 NSPopover 显示时的 `store.snapshots` 快照值，之后无论后台 refresh 多少次，Pop 都不更新（除非用户触发 `@State` 变化或重新打开 Pop）。

---

## 3. 修复

### 3.1 改 PopupView 的订阅结构

```swift
public struct PopupView: View {
    @ObservedObject public var appState: AppState
    /// [BUG-2026-06-20-01] 单独把 store 暴露成 @ObservedObject，让 SwiftUI 订阅 store.objectWillChange。
    /// AppState.store 是 `let` 属性（不是 @Published），store.snapshots 变化不会触发 appState.objectWillChange，
    /// 仅靠 @ObservedObject var appState 订阅时，PopupView body 不会响应 store.snapshots 变化，
    /// 导致 Popup 数字卡在用户打开 Popup 那一刻、状态栏持续更新——形成"状态栏新、Pop 旧"的稳定分裂。
    @ObservedObject private var store: QuotaStore
    @State private var diagFeedback: String?

    public init(appState: AppState) {
        self.appState = appState
        self.store = appState.store
    }
    ...
}
```

body 内 `appState.store.xxx` 全部改为 `store.xxx`（snapshots / errors / isRefreshing / lastRefreshAt / hasAnySnapshot）。`appState.refresh()`、`appState.exportDiagnostics()` 等方法仍走 `appState`（这些是 AppState 的方法而非 store 属性）。

### 3.2 改动清单

| 文件 | 改动 |
|------|------|
| `QuotaMonitor/UI/Popup/PopupView.swift` | 加 `@ObservedObject private var store: QuotaStore`，init 注入；body 内 5 处 `appState.store.xxx` → `store.xxx` |
| `QuotaMonitor/Resources/Info.plist` | `CFBundleShortVersionString` 1.0.11 → 1.0.12 |
| `CHANGELOG.md` | 顶部新增 `## [1.0.12] - 2026-06-20` 段 |
| `docs/incident-reports/2026-06-20-popup-vs-menubar-stuck-at-open-time.md` | 本报告 |

### 3.3 SettingsView 是否也有同样问题？

不。`SettingsView` 直接 `@ObservedObject var settings: SettingsStore`，传入的就是 `SettingsStore` 本身（不是 `AppState.settings`），所以 SwiftUI 直接订阅 `settings.objectWillChange`，settings 的 @Published 变化会触发 body 重算。无此 bug。

### 3.4 是否有别处类似风险？

无其他 `appState.store.xxx` 引用（grep 全项目仅 PopupView 内 5 处）。其它视图（SettingsView 9 处）都用 `@ObservedObject var settings: SettingsStore` 直接订阅。无后续修复需要。

---

## 4. 验证

### 4.1 编译

`swift build -c release` → `Build complete! (9.69s)`，0 error，2 warning（已存在的 `NotificationManager` Swift 6 actor 隔离警告，与本修复无关）。

### 4.2 测试

`swift test` → **136/136 passed**（基线 1.0.11 = 136，本轮无新增用例，无回归）。

> 注：SwiftUI view body 重算需要 UI runtime（NSHostingController view display 周期），无法用纯 unit test 验证；本次修复为 SwiftUI idiomatic（@ObservedObject 标准用法），靠实机验证（开 Pop 后等 30s 看 Pop 数字是否随状态栏同步更新）覆盖。

### 4.3 实机验证（用户执行）

1. 替换 `/Applications/QuotaMonitor.app` 后启动
2. 状态栏显示 `K 0 M 18 G 11`（假设当前快照）
3. 点击状态栏图标弹出 Pop，应显示 `K 0 M 18 G 11`
4. 等待 30~60s（后台 refresh 一轮）
5. 假设状态栏刷新为 `K 0 M 25 G 14`
6. **关键验证**：**Pop 也应同步刷新为 `K 0 M 25 G 14`**，无需关闭重开

---

## 5. v1.0.6 修复遗漏回顾（流程沉淀）

v1.0.6 修复了"状态栏 vs Pop 数字分裂"（`objectWillChange` 时序 + `displayPercent` 取整），但**只修了状态栏的订阅链路（改用 `appState.store.$snapshots` 直接订阅）**，**没有同步检查 PopupView 是否也走相同的订阅**。

本次 bug 是同一类（"UI 订阅了错误层级的 ObservableObject"）的再次发生，区别在于：v1.0.6 是时序问题（同一份快照读到旧值），本次是订阅缺失（完全没收到变化通知）。

### 流程改进建议

| 规则 | 说明 |
|------|------|
| 任何引用 `appState.store.xxx` 的 view | 必须独立 `@ObservedObject var store: QuotaStore`，不能仅靠 `@ObservedObject var appState: AppState` 隐式订阅 |
| 任何新增 view 引用 `AppState` 的内部组件 | 启动时由 `Plan` agent 检查订阅链路完整性 |
| `AppState` 的属性变化 | 如果想让所有 view 响应，必须把对应属性升为 `@Published`，或在 view 层显式 `@ObservedObject` |

---

## 6. 附录：相关历史修复

| 版本 | Bug | 根因 | 修复 |
|------|-----|------|------|
| v1.0.2 | 阈值 slider 拖动后颜色滞后 1 帧 | 监听 `SettingsStore.objectWillChange`（willSet 触发） | 改 `Publishers.Merge3` 监听 `$warningThreshold` 等三个 `$publisher` |
| v1.0.6 | 状态栏 vs Pop 数字分裂（"2 vs 1"） | A: 状态栏监听 `objectWillChange` 读到旧快照；B: 状态栏用 `Int()` 截断、Pop 用 `%.0f` 四舍五入 | A: 改 `appState.store.$snapshots` 直接订阅；B: 统一 `ProviderQuota.displayPercent`（v1.0.6 仅修状态栏订阅，**PopupView 订阅层漏改**） |
| **v1.0.12** | **Pop 数字卡在打开时刻** | **PopupView 仅订阅 `appState.objectWillChange`，而 `appState.store` 是 `let` 属性，订阅链路断裂** | **PopupView 加独立 `@ObservedObject private var store: QuotaStore`** |

> [!] 同一类（"订阅层级错误"）的 v1.0.2 → v1.0.6 → v1.0.12 连续三次发生。建议把"任何 ObservableObject 的嵌套属性引用都必须显式建立订阅"加入 CLAUDE.md 陷阱表，作为新的必记陷阱。