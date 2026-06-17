# QuotaMonitor 开机自动启动功能设计文档

> 日期：2026-06-17
> 版本：v1.0.4
> 状态：待实现

---

## 1. 需求概述

为 QuotaMonitor 增加"开机自动启动"选项：
- 设置面板新增 Toggle，默认关闭
- 用户打开后，应用在 macOS 登录时自动启动
- 需要处理 macOS 13+ 的登录项授权流程

---

## 2. 技术选型

采用 Apple 在 macOS 13 引入的 **SMAppService** API。

理由：
- Apple 主推的现代登录项 API
- 可直接将主应用注册为登录项，无需单独 Helper 应用
- 比旧的 `SMLoginItemSetEnabled` 更简洁、未来兼容性更好

兼容性代价：
- 项目最低系统版本需从 macOS 12 提升到 **macOS 13**

---

## 3. 系统要求变更

以下文件需更新最低系统版本为 macOS 13：

| 文件 | 变更 |
|------|------|
| `Package.swift` | `platforms: [.macOS(.v13)]` |
| `QuotaMonitor/Resources/Info.plist` | `LSMinimumSystemVersion` 改为 `13.0` |
| `README.md` | 系统要求徽章和文字改为 macOS 13+ |
| `USER_GUIDE.md` | 系统要求改为 macOS 13+ |

---

## 4. 新增/修改组件

### 4.1 LoginItemManager（新增）

封装 SMAppService 操作：

```swift
import ServiceManagement

@MainActor
final class LoginItemManager {
    static let shared = LoginItemManager()

    var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}
```

### 4.2 SettingsStore（扩展）

新增 `@Published` 属性：

```swift
@Published public var launchAtLogin: Bool {
    didSet { defaults.set(launchAtLogin, forKey: Keys.launchAtLogin) }
}
```

初始化默认值：`false`

UserDefaults key：`qm.launchAtLogin`

### 4.3 SettingsView（扩展）

新增"启动"Section：

- Toggle："登录时自动启动 QuotaMonitor"
- 状态文本：根据 `LoginItemManager.status` 显示
  - `.enabled`：已启用
  - `.requiresApproval`：需要在系统设置中允许
  - `.notRegistered`：未启用
- 按钮：当状态为 `.requiresApproval` 时显示"打开系统设置"

### 4.4 AppDelegate（可选调整）

应用启动时可根据 `launchAtLogin` 设置同步一次 SMAppService 状态，确保设置与实际状态一致。

---

## 5. 交互流程

```
用户打开 Toggle
  → SettingsStore.launchAtLogin = true
  → LoginItemManager.register()
  → 检查 LoginItemManager.status
     ├─ .enabled          → 显示"已启用"
     ├─ .requiresApproval → 自动打开系统设置 → 登录项
     │                      显示提示："请在系统设置中允许，完成后可重启应用"
     └─ .notRegistered    → 显示"未启用"
```

---

## 6. 状态显示规则

| SMAppService 状态 | UI 显示 |
|------------------|---------|
| `.notRegistered` | "未启用" |
| `.enabled` | "已启用" |
| `.requiresApproval` | "需要在系统设置中允许" + 打开设置按钮 |
| `.notFound` | "状态异常" |

---

## 7. 测试策略

新增 `LoginItemManagerTests`：

- 测试 `status` 查询不崩溃
- 测试 `SettingsStore.launchAtLogin` 的 UserDefaults 持久化
- 不测试 SMAppService 实际注册行为（需要系统权限，不适合单元测试）

---

## 8. 发版计划

- 版本号：v1.0.4
- 更新 `CHANGELOG.md` 新增 v1.0.4 章节
- 运行 `./scripts/release.sh 1.0.4`
- GitHub Actions 自动 build + 发 Release
- 下载 Release dmg 更新本地：
  - `~/Downloads/QuotaMonitor-1.0.4.dmg`
  - `deliverables/QuotaMonitor-1.0.4.dmg`

---

## 9. 已知限制

- 需要用户手动在系统设置 → 登录项中授权（Apple 强制）
- 授权后可能需要重启应用才能正确反映 `.enabled` 状态
- 最低系统版本提升至 macOS 13

---

## 10. 涉及文件清单

- 新增：`QuotaMonitor/Services/Launch/LoginItemManager.swift`
- 新增：`QuotaMonitorTests/LoginItemManagerTests.swift`
- 修改：`QuotaMonitor/State/SettingsStore.swift`
- 修改：`QuotaMonitor/UI/Settings/SettingsView.swift`
- 修改：`QuotaMonitor/App/AppDelegate.swift`
- 修改：`Package.swift`
- 修改：`QuotaMonitor/Resources/Info.plist`
- 修改：`README.md`
- 修改：`USER_GUIDE.md`
- 修改：`CHANGELOG.md`
