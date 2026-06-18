# 状态栏与 Popup 百分比显示不一致 — 根因分析

> 报告日期：2026-06-18
> 阶段：阶段 1（分析与计划）· 等待用户拍板
> 涉及版本：v1.0.5 → 拟修 v1.0.6
> 处理流程：bug 反馈 2 阶段 HITL（本报告属节点 1）

---

## 0. 结论摘要（TL;DR）

Bug **属实**，根因有**两层**，必须同时修：

| 层 | 根因 | 性质 | 是否直接导致本次 2 / 1 |
|----|------|------|------------------------|
| A | 状态栏监听 `objectWillChange`，读到上一周期的旧快照 | 时序缺陷 | 是（主因） |
| B | 状态栏用截断 `Int()`、popup 用四舍五入 `%.0f` | 取整不一致 | 否（独立隐患，修 A 后仍会在边界复发） |

一句话：**状态栏比 popup 滞后一个刷新周期**，叠加两处取整方式不同。当 MiniMax 的已用百分比从 `2.x` 掉到 `1.x` 时，状态栏卡在旧的 `2`，popup 显示新的 `1`。

---

## 1. 现象

用户实测：

- 点击状态栏图标弹出 Popup，MiniMax 卡片显示 **1%**
- 但状态栏字母 `M` 后面显示的数字是 **2**
- 两处本应同步，实际不同步

---

## 2. 数据流追踪（证据链）

先确认两处 UI 是否读同一个数据源：

```
MiniMax API
   │  current_interval_remaining_percent (剩余%)
   ▼
MiniMaxProvider.fetchQuota()          MiniMaxProvider.swift:65-66
   │  usedPercent = 100 - remainingPercent
   ▼
NetworkingService.applySmoothing()    NetworkingService.swift:98-118
   │  同窗口内 used 不倒退（防被动流失），产出 smoothed snapshot
   ▼
QuotaStore.snapshots  (@Published)    QuotaStore.swift:16
   │
   ├─► 状态栏  MenuBarController.refreshStatusItemTitle()   读 snapshots[kind]?.primaryUsedPercent
   └─► Popup   ProviderCardView                            读 quota?.primaryUsedPercent
```

**关键事实**：两处 UI 读的是**同一个字段** `primaryUsedPercent`（定义于 `QuotaMonitor/Core/Models/ProviderQuota.swift:40`），它就是 `primaryWindow?.usedPercent`（`QuotaWindow.swift:29`，纯计算属性 `used/total*100`）。

> 数据源相同 → 排除"两处读不同字段"。矛头转向**渲染层**。

---

## 3. 根因 A：状态栏时序滞后（主因）

### 3.1 代码证据

`QuotaStore.snapshots` 是 `@Published`：

```swift
// QuotaStore.swift:16
@Published public private(set) var snapshots: [ProviderKind: ProviderQuota] = [:]
```

但状态栏监听的是 `objectWillChange`，**不是** `$snapshots`：

```swift
// MenuBarController.swift:80-87
private func observeState() {
    appState.store.objectWillChange              // <-- 问题在这
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.refreshStatusItemTitle()
        }
        .store(in: &cancellables)
    ...
}
```

### 3.2 机制

`@Published` 的 `objectWillChange` 在属性的 **`willSet`** 阶段触发——此刻 `snapshots` 的**新值还没写入**。于是：

1. `snapshots` 将从 `旧值` 变为 `新值`
2. `objectWillChange` 先 fire → sink 回调执行 `refreshStatusItemTitle()`
3. 回调里读 `appState.store.snapshots` → 拿到的还是**旧值**
4. 状态栏渲染旧值

而 popup 走 SwiftUI `@ObservedObject` 标准流程，在**下一帧**重新求值 body，此时 `snapshots` 已是新值 → popup 显示新值。

**结果：状态栏始终比 popup 滞后一个刷新周期。**

### 3.3 如何导致 2 / 1

- 刷新 N-1：MiniMax `usedPercent = 2.x` → 状态栏渲染 `Int(2.x) = 2`
- 刷新 N：MiniMax `usedPercent` 降到 `1.x`（被动流失或真实下降），`snapshots` 更新
  - 状态栏收到 `objectWillChange`（willSet），读到的还是旧的 `2.x` → 渲染 `2`
  - popup 读到新的 `1.x` → 显示 `1`

> 这正是项目 `CLAUDE.md` 陷阱表记录的「`@Published.objectWillChange` 时序」陷阱。上次（v1.0.2）只修了阈值 slider 那条（改用 `$publisher` 的 `Merge3`，见 `MenuBarController.swift:94-104`），**`snapshots` 这条漏网了**。

---

## 4. 根因 B：取整方式不一致（次因）

### 4.1 代码证据

| 位置 | 代码 | 取整方式 |
|------|------|----------|
| 状态栏 `MenuBarController.swift:194` | `" \(Int(used))"` | **截断**（向零） |
| Popup `ProviderCardView.swift:32` | `String(format: "%.0f%%", used)` | **四舍五入** |

同一个非整数值，两处必然差 1。例如 `used = 1.6`：状态栏 `Int(1.6) = 1`，popup `"%.0f" = 2`。

### 4.2 全代码库取整现状（系统性不统一）

| 文件:行 | 用法 | 方式 |
|---------|------|------|
| `MenuBarController.swift:194` | `Int(used)` | 截断 |
| `AlertStateMachine.swift:80` | `Int(window.usedPercent)` | 截断 |
| `NotificationManager.swift:62` | `Int(event.usedPercent)` | 截断 |
| `AppState.swift:100` | `Int(event.usedPercent)` | 截断 |
| `ProviderCardView.swift:32` | `String(format: "%.0f")` | 四舍五入 |
| `NotificationManager.swift:91` | `String(format: "%.0f")` | 四舍五入 |

> 截断与四舍五入混用，是潜伏的不一致源。

---

## 5. 数学反证（为何两层必须同修）

对任意正数 X：

```
round(X) >= Int(X)    恒成立
```

所以**纯取整差异只能让 popup >= 状态栏**，绝不可能出现本次的「状态栏 2 > popup 1」。

这反向证明：**必然存在根因 A 的时序滞后**（状态栏读到的是更旧的、更大的值）。

同时这也说明：即便修好根因 A，根因 B 仍会在 `x.5` 边界制造 `popup = 状态栏 ± 1` 的新不一致。**两层必须一起修。**

---

## 6. 修复方案

### 6.1 修根因 A：改监听 `$snapshots`

`MenuBarController.observeState()`，把数据快照那条订阅从 `objectWillChange` 换成 `$snapshots`（`@Published` 的 projected value，在 `didSet` 后 send，读到的是新值）。阈值那条 `Merge3` 保持不动。

```swift
// 改前
appState.store.objectWillChange
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.refreshStatusItemTitle() }
    .store(in: &cancellables)

// 改后
appState.store.$snapshots
    .receive(on: DispatchQueue.main)
    .sink { [weak self] _ in self?.refreshStatusItemTitle() }
    .store(in: &cancellables)
```

### 6.2 修根因 B：统一取整

在 `ProviderQuota` 增加一个**专供显示**的整数百分比，状态栏与 popup 都引用它，保证永远一致：

```swift
// ProviderQuota.swift（新增）
/// UI 显示用的整数百分比（四舍五入）。
/// 状态栏、popup 等所有展示位统一用它，杜绝截断/四舍五入混用导致的不一致。
public var displayPercent: Int? {
    primaryUsedPercent.map { Int($0.rounded()) }
}
```

状态栏：

```swift
// MenuBarController.swift 改前
if let used = snapshots[kind]?.primaryUsedPercent {
    numberText = " \(Int(used))"
    numberColor = Self.nsColor(for: used, settings: appState.settings)
}

// 改后：数字用 displayPercent（int），颜色仍用原始 double 判阈值
if let snap = snapshots[kind], let raw = snap.primaryUsedPercent {
    numberText = " \(snap.displayPercent ?? 0)"
    numberColor = Self.nsColor(for: raw, settings: appState.settings)
}
```

popup：

```swift
// ProviderCardView.swift 改前
} else if let used = quota?.primaryUsedPercent {
    Text(String(format: "%.0f%%", used))
        .foregroundColor(SemanticColors.color(for: used))

// 改后：数字用 displayPercent，颜色仍用原始 double
} else if let used = quota?.displayPercent, let raw = quota?.primaryUsedPercent {
    Text("\(used)%")
        .foregroundColor(SemanticColors.color(for: raw))
}
```

> [!] **关键细节**：取整只作用于「显示的数字」；**颜色阈值判定仍用原始 `Double` 百分比**。否则在阈值边界（如 60%/86%/95%）会出现"数字显示 60、但颜色还是绿色（因为原始值 59.6）"的错位。

### 6.3 改动清单

| 文件 | 改动 |
|------|------|
| `QuotaMonitor/Core/Models/ProviderQuota.swift` | 新增 `displayPercent` 计算属性 |
| `QuotaMonitor/UI/MenuBar/MenuBarController.swift` | 订阅改 `$snapshots`；数字改 `displayPercent` |
| `QuotaMonitor/UI/Popup/ProviderCardView.swift` | 数字改 `displayPercent` |

---

## 7. 验证计划

| 验证项 | 方法 | 通过标准 |
|--------|------|----------|
| 取整一致性 | 新增单测：`usedPercent = 1.6 / 2.5 / 0.4 / 59.6` 等边界值，断言状态栏格式化结果 == popup 格式化结果 | 全过 |
| 时序消除 | 代码层改 `$snapshots`；手动运行，构造两次刷新让 MiniMax 值跨整数边界 | 状态栏与 popup 同步，无滞后 |
| 颜色未受影响 | 手动确认阈值边界（59.6 / 60.0）颜色判定仍准确 | 颜色按原始 double 判定 |
| 回归 | `swift test` | 全过（当前 105/105 基线） |
| 实机 | 打包 `.app` 替换 `/Applications`，观察 MiniMax | 状态栏与 popup 数字一致 |

---

## 8. 版本与文档

- 版本号：`Info.plist` 的 `CFBundleShortVersionString`：`1.0.5` → `1.0.6`
- `CHANGELOG.md` 顶部新增 `## [1.0.6] - 2026-06-18` 段，记录双层根因与修复

---

## 9. 流程固化（用户要求：写入全局记忆与 SOP）

- **全局记忆**：写一条 `feedback` 类型 memory，内容为「bug 反馈 = 2 阶段 HITL + 4 步操作 + 2 确认节点」标准流程
- **SOP 文档**：新增 `docs/SOP-bug-fix.md`（或并入 `CLAUDE.md`），记录上述 bug 处理标准流程，供后续所有 bug 反馈遵循

---

## 10. 节点 1 · 待用户拍板

请就以下 4 点确认：

1. **根因分析（双层 A + B）是否认可？**
2. **修复方案**（改 `$snapshots` + 统一 `displayPercent`）是否按此执行？
3. **取整方向**：`displayPercent` 用四舍五入（推荐，更直观）还是截断？
4. **SOP 文档位置**：`docs/SOP-bug-fix.md`（推荐，独立可检索）还是并入 `CLAUDE.md`？

确认后，我将进入执行：改代码 + 写 memory + 写 SOP，完成后**停在节点 2**，等你确认「替换 `/Applications` + 提交 GitHub」。
