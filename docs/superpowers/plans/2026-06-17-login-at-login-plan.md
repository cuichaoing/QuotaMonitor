# QuotaMonitor 开机自动启动功能实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 QuotaMonitor 增加"登录时自动启动"选项，使用 SMAppService API（macOS 13+）。

**Architecture:** 新增 `LoginItemManager` 封装 SMAppService 注册/注销/状态查询；`SettingsStore` 持久化用户选择；`SettingsView` 提供 Toggle 和状态提示；`AppDelegate` 在启动时同步状态。

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, ServiceManagement, SMAppService

## Global Constraints

- 最低系统版本：macOS 13（原 macOS 12）
- 默认行为：开机自启默认关闭
- 权限模型：SMAppService 注册后，用户需到"系统设置 → 登录项"手动允许
- 无 Co-Authored-By: Claude commit message
- 所有变更需通过 `swift test`（105+ 测试）

---

## File Structure

| 文件 | 操作 | 职责 |
|------|------|------|
| `QuotaMonitor/Services/Launch/LoginItemManager.swift` | 创建 | 封装 SMAppService API |
| `QuotaMonitorTests/LoginItemManagerTests.swift` | 创建 | 测试 LoginItemManager 和 SettingsStore 持久化 |
| `QuotaMonitor/State/SettingsStore.swift` | 修改 | 增加 `launchAtLogin` 属性 |
| `QuotaMonitor/UI/Settings/SettingsView.swift` | 修改 | 增加开机自启 UI Section |
| `QuotaMonitor/App/AppDelegate.swift` | 修改 | 启动时同步 SMAppService 状态 |
| `Package.swift` | 修改 | 提升最低版本到 macOS 13，链接 ServiceManagement |
| `QuotaMonitor/Resources/Info.plist` | 修改 | `LSMinimumSystemVersion` 改为 13.0 |
| `README.md` | 修改 | 系统要求改为 macOS 13+ |
| `USER_GUIDE.md` | 修改 | 系统要求改为 macOS 13+，增加开机自启说明 |
| `CHANGELOG.md` | 修改 | 增加 v1.0.4 变更记录 |

---

### Task 1: 提升最低系统版本到 macOS 13 并链接 ServiceManagement

**Files:**
- 修改：`Package.swift`
- 修改：`QuotaMonitor/Resources/Info.plist`
- 修改：`README.md`
- 修改：`USER_GUIDE.md`

**Interfaces:**
- 无新增接口

- [ ] **Step 1: 修改 Package.swift**

将 `platforms: [.macOS(.v12)]` 改为 `platforms: [.macOS(.v13)]`，并为 executableTarget 增加 ServiceManagement 链接：

```swift
.executableTarget(
    name: "QuotaMonitor",
    path: "QuotaMonitor",
    exclude: [
        "Resources/Info.plist",
        "Resources/QuotaMonitor.entitlements"
    ],
    linkerSettings: [
        .linkedFramework("ServiceManagement")
    ]
)
```

- [ ] **Step 2: 修改 Info.plist**

修改 `QuotaMonitor/Resources/Info.plist`：

```xml
<key>LSMinimumSystemVersion</key>
<string>13.0</string>
```

- [ ] **Step 3: 修改 README.md**

将系统要求从 `macOS 12+` 改为 `macOS 13+`，并更新徽章：

```markdown
[![Platform: macOS 13+](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey.svg)](#系统要求)
```

正文：

```markdown
- macOS 13 (Ventura) 及以上
```

- [ ] **Step 4: 修改 USER_GUIDE.md**

将系统要求改为 `macOS 13+`，并在"进阶配置"或"日常使用"后新增开机自启小节：

```markdown
## 5. 开机自动启动

设置 → 启动 → 打开"登录时自动启动 QuotaMonitor"。

首次开启时，macOS 会要求你在"系统设置 → 登录项"中允许 QuotaMonitor。点击设置面板中的"打开系统设置"按钮，勾选 QuotaMonitor 即可。
```

- [ ] **Step 5: 验证 build**

```bash
cd /Users/cc/Documents/我的代码/2026.6.17-QuotaMonitor
swift build -c release
```

Expected: 编译成功，无 error。

- [ ] **Step 6: Commit**

```bash
git add Package.swift QuotaMonitor/Resources/Info.plist README.md USER_GUIDE.md
git commit -m "chore: 最低系统版本提升至 macOS 13，链接 ServiceManagement"
```

---

### Task 2: 实现 LoginItemManager

**Files:**
- 创建：`QuotaMonitor/Services/Launch/LoginItemManager.swift`
- 测试：`QuotaMonitorTests/LoginItemManagerTests.swift`

**Interfaces:**
- Produces: `LoginItemManager.shared.status`, `LoginItemManager.shared.register()`, `LoginItemManager.shared.unregister()`, `LoginItemManager.shared.openSystemSettings()`

- [ ] **Step 1: 写失败测试**

创建 `QuotaMonitorTests/LoginItemManagerTests.swift`：

```swift
import XCTest
import ServiceManagement
@testable import QuotaMonitor

@MainActor
final class LoginItemManagerTests: XCTestCase {
    func testSharedInstanceExists() {
        XCTAssertNotNil(LoginItemManager.shared)
    }

    func testStatusQueryDoesNotCrash() {
        let status = LoginItemManager.shared.status
        XCTAssertTrue([.notRegistered, .enabled, .requiresApproval].contains(status))
    }

    func testOpenSystemSettingsURLIsValid() {
        let url = LoginItemManager.systemSettingsURL
        XCTAssertNotNil(url)
        XCTAssertTrue(url?.absoluteString.hasPrefix("x-apple.systempreferences:") ?? false)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
swift test --filter LoginItemManagerTests
```

Expected: 编译失败，`LoginItemManager` 未定义。

- [ ] **Step 3: 实现 LoginItemManager**

创建 `QuotaMonitor/Services/Launch/LoginItemManager.swift`：

```swift
//
//  LoginItemManager.swift
//  QuotaMonitor
//
//  封装 SMAppService 登录项管理
//

import AppKit
import ServiceManagement

/// 管理 QuotaMonitor 的开机自动启动（登录项）。
/// 使用 Apple 主推的 SMAppService API（macOS 13+）。
@MainActor
public final class LoginItemManager: @unchecked Sendable {
    public static let shared = LoginItemManager()

    /// 打开"系统设置 → 登录项"的 URL
    public static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    /// 当前登录项状态
    public var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    private init() {}

    /// 将主应用注册为登录项。
    /// 抛出异常表示注册失败（如未授权、服务未找到等）。
    public func register() throws {
        try SMAppService.mainApp.register()
    }

    /// 取消主应用的登录项注册。
    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    /// 打开系统设置中的"登录项"页面，引导用户手动允许。
    public func openSystemSettings() {
        guard let url = Self.systemSettingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

```bash
swift test --filter LoginItemManagerTests
```

Expected: 3 个测试全部通过。

- [ ] **Step 5: Commit**

```bash
git add QuotaMonitor/Services/Launch/LoginItemManager.swift QuotaMonitorTests/LoginItemManagerTests.swift
git commit -m "feat: 增加 LoginItemManager 封装 SMAppService"
```

---

### Task 3: SettingsStore 增加 launchAtLogin 持久化

**Files:**
- 修改：`QuotaMonitor/State/SettingsStore.swift`
- 测试：`QuotaMonitorTests/LoginItemManagerTests.swift`（扩展）

**Interfaces:**
- Produces: `SettingsStore.launchAtLogin: Bool`

- [ ] **Step 1: 写失败测试**

在 `QuotaMonitorTests/LoginItemManagerTests.swift` 末尾添加：

```swift
extension LoginItemManagerTests {
    func testSettingsStoreLaunchAtLoginDefaultsToFalse() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(defaults: defaults)
        XCTAssertFalse(store.launchAtLogin)
    }

    func testSettingsStoreLaunchAtLoginPersistence() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SettingsStore(defaults: defaults)
        store.launchAtLogin = true

        let secondStore = SettingsStore(defaults: defaults)
        XCTAssertTrue(secondStore.launchAtLogin)
    }
}
```

- [ ] **Step 2: 运行测试确认失败**

```bash
swift test --filter LoginItemManagerTests
```

Expected: 编译失败，`SettingsStore` 没有 `launchAtLogin`。

- [ ] **Step 3: 实现 launchAtLogin**

修改 `QuotaMonitor/State/SettingsStore.swift`：

在 `@Published public var dangerThreshold` 后添加：

```swift
    /// 开机自动启动
    @Published public var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
    }
```

在 init 中 `self.dangerThreshold = ...` 后添加：

```swift
        self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
```

在 Keys 枚举中添加：

```swift
        static let launchAtLogin = "qm.launchAtLogin"
```

- [ ] **Step 4: 运行测试确认通过**

```bash
swift test --filter LoginItemManagerTests
```

Expected: 5 个测试全部通过。

- [ ] **Step 5: Commit**

```bash
git add QuotaMonitor/State/SettingsStore.swift QuotaMonitorTests/LoginItemManagerTests.swift
git commit -m "feat: SettingsStore 增加 launchAtLogin 持久化"
```

---

### Task 4: SettingsView 增加开机自启 UI

**Files:**
- 修改：`QuotaMonitor/UI/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: `SettingsStore.launchAtLogin`, `LoginItemManager.shared.status`, `LoginItemManager.shared.register()`, `LoginItemManager.shared.unregister()`, `LoginItemManager.shared.openSystemSettings()`

- [ ] **Step 1: 实现 LaunchAtLoginSection**

在 `QuotaMonitor/UI/Settings/SettingsView.swift` 末尾（`ThresholdSlider` 之前或之后）添加：

```swift
// MARK: - LaunchAtLoginSection

private struct LaunchAtLoginSection: View {
    @ObservedObject var settings: SettingsStore
    @State private var serviceStatus: SMAppService.Status = LoginItemManager.shared.status

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text("启动")
                .font(.headline)

            Toggle(isOn: Binding(
                get: { settings.launchAtLogin },
                set: { newValue in
                    settings.launchAtLogin = newValue
                    Task { @MainActor in
                        await syncLaunchAtLogin(enabled: newValue)
                    }
                }
            )) {
                Text("登录时自动启动 QuotaMonitor")
            }
            .toggleStyle(.checkbox)

            HStack(spacing: Spacing.xs) {
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)

                Spacer()

                if serviceStatus == .requiresApproval {
                    Button("打开系统设置") {
                        LoginItemManager.shared.openSystemSettings()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    private var statusText: String {
        switch serviceStatus {
        case .enabled:
            return "已启用"
        case .requiresApproval:
            return "需要在系统设置 → 登录项中允许"
        case .notRegistered:
            return "未启用"
        case .notFound:
            return "状态异常"
        @unknown default:
            return "未知状态"
        }
    }

    private var statusColor: Color {
        switch serviceStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notRegistered: return .secondary
        case .notFound: return .red
        @unknown default: return .secondary
        }
    }

    private func syncLaunchAtLogin(enabled: Bool) async {
        do {
            if enabled {
                try LoginItemManager.shared.register()
            } else {
                try LoginItemManager.shared.unregister()
            }
        } catch {
            // 注册失败时保持静默，UI 会显示实际状态
        }
        serviceStatus = LoginItemManager.shared.status
    }
}
```

- [ ] **Step 2: 将 Section 加入 SettingsView body**

在 `SettingsView.body` 的 `ScrollView` 中，在 `providersSection` 之前或 `advancedSection` 之前插入：

```swift
                    launchAtLoginSection
```

并添加对应的 view builder：

```swift
    private var launchAtLoginSection: some View {
        LaunchAtLoginSection(settings: settings)
    }
```

- [ ] **Step 3: 验证 build**

```bash
swift build -c release
```

Expected: 编译成功。

- [ ] **Step 4: Commit**

```bash
git add QuotaMonitor/UI/Settings/SettingsView.swift
git commit -m "feat: 设置面板增加开机自启选项"
```

---

### Task 5: AppDelegate 启动时同步 SMAppService 状态

**Files:**
- 修改：`QuotaMonitor/App/AppDelegate.swift`

**Interfaces:**
- Consumes: `SettingsStore.shared.launchAtLogin`, `LoginItemManager.shared.status`, `LoginItemManager.shared.register()`, `LoginItemManager.shared.unregister()`

- [ ] **Step 1: 实现启动同步**

修改 `QuotaMonitor/App/AppDelegate.swift`，在 `applicationDidFinishLaunching` 中添加同步逻辑：

```swift
    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 启动菜单栏
        menuBarController = MenuBarController(appState: appState)

        // 2. 同步开机自启状态：确保 SMAppService 与 SettingsStore 一致
        syncLaunchAtLogin()

        // 3. 启动数据流
        appState.bootstrap()

        // 4. 确保不显示在 Dock
        NSApp.setActivationPolicy(.accessory)
    }

    private func syncLaunchAtLogin() {
        let settings = appState.settings
        let manager = LoginItemManager.shared
        let status = manager.status

        // 用户想开启，但系统未注册或需要授权 → 尝试注册
        if settings.launchAtLogin {
            if status == .notRegistered {
                try? manager.register()
            }
        } else {
            // 用户想关闭，但系统仍注册 → 注销
            if status == .enabled || status == .requiresApproval {
                try? manager.unregister()
            }
        }
    }
```

- [ ] **Step 2: 验证 build**

```bash
swift build -c release
```

Expected: 编译成功。

- [ ] **Step 3: Commit**

```bash
git add QuotaMonitor/App/AppDelegate.swift
git commit -m "feat: 启动时同步开机自启状态"
```

---

### Task 6: 全量测试

**Files:**
- 所有已修改文件

- [ ] **Step 1: 运行全部测试**

```bash
swift test
```

Expected: 105+ 测试全部通过，无失败。

- [ ] **Step 2: Commit（如测试通过）**

如果全量测试通过，无需单独 commit（已在各 task 中 commit）。

---

### Task 7: 更新 CHANGELOG 并发版 v1.0.4

**Files:**
- 修改：`CHANGELOG.md`
- 触发：`./scripts/release.sh 1.0.4`

- [ ] **Step 1: 更新 CHANGELOG.md**

在 CHANGELOG 顶部新增 v1.0.4 章节：

```markdown
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
```

- [ ] **Step 2: Commit CHANGELOG**

```bash
git add CHANGELOG.md
git commit -m "docs: 更新 CHANGELOG v1.0.4"
```

- [ ] **Step 3: 发版**

```bash
./scripts/release.sh 1.0.4
```

Expected: release workflow 成功，GitHub Release v1.0.4 发布。

---

### Task 8: 更新本地交付物

**Files:**
- `~/Downloads/QuotaMonitor-1.0.4.dmg`
- `deliverables/QuotaMonitor-1.0.4.dmg`

- [ ] **Step 1: 下载新版 dmg**

```bash
cd /tmp
curl -L -O https://github.com/cuichaoing/QuotaMonitor/releases/download/v1.0.4/QuotaMonitor-1.0.4.dmg
```

- [ ] **Step 2: 同步到下载目录和交付文件夹**

```bash
cp /tmp/QuotaMonitor-1.0.4.dmg "$HOME/Downloads/QuotaMonitor-1.0.4.dmg"
cp /tmp/QuotaMonitor-1.0.4.dmg deliverables/QuotaMonitor-1.0.4.dmg
ls -lh "$HOME/Downloads/QuotaMonitor-1.0.4.dmg" deliverables/QuotaMonitor-1.0.4.dmg
```

Expected: 两个文件大小一致，约 300-400KB。

---

## Spec Coverage Check

| 设计文档要求 | 实现任务 |
|-------------|---------|
| 最低系统版本 macOS 13 | Task 1 |
| 使用 SMAppService | Task 2 |
| LoginItemManager 封装 | Task 2 |
| SettingsStore.launchAtLogin | Task 3 |
| SettingsView UI | Task 4 |
| AppDelegate 启动同步 | Task 5 |
| 测试覆盖 | Task 2, 3, 6 |
| 发版 v1.0.4 | Task 7 |
| 更新本地 dmg | Task 8 |

## Placeholder Scan

无 TBD/TODO/"实现 later"/"适当处理"等占位符。

## Type Consistency Check

- `LoginItemManager.register()` / `unregister()` 全项目一致
- `SettingsStore.launchAtLogin` 在 SettingsView 和 AppDelegate 中命名一致
- `SMAppService.Status` 在 LoginItemManager 和 UI 中一致

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-17-login-at-login-plan.md`.

Two execution options:

**1. Subagent-Driven (recommended)** - Dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch execution with checkpoints

Which approach?
