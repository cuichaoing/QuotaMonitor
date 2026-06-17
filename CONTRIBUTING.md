# Contributing to QuotaMonitor

欢迎贡献！本指南描述如何提 Issue、PR，以及本项目的开发约定。

## 提 Issue

### Bug 报告
请使用 [Bug Report 模板](.github/ISSUE_TEMPLATE/bug_report.md)，必填：
- 操作系统版本（macOS 13.5 / 14.2 / ...）
- QuotaMonitor 版本（v1.0.2 等）
- 复现步骤
- 预期 vs 实际行为
- 截图（如果是 UI 问题）

### 功能请求
请使用 [Feature Request 模板](.github/ISSUE_TEMPLATE/feature_request.md)，说明：
- 想解决什么问题
- 替代方案（如果有）

## 提 PR

### 本地开发环境
- macOS 12+
- Swift 5.9+（Xcode 15+）
- 无需额外依赖（纯 SPM）

### 构建 & 测试
```bash
# 拉代码
git clone https://github.com/你的用户名/QuotaMonitor.git
cd QuotaMonitor

# Debug 构建
swift build

# Release 构建
swift build -c release

# 跑测试（必须全过，105/105）
swift test

# 打包 .app（必须，否则 UNUserNotificationCenter 崩溃）
cp .build/release/QuotaMonitor build/QuotaMonitor.app/Contents/MacOS/QuotaMonitor
codesign --force --deep --sign - build/QuotaMonitor.app
```

### 代码风格
- Swift 5.9 语法，async/await 优先于回调
- 缩进 4 空格（项目用 .editorconfig）
- 公共 API 必须有 doc comment（`///`）
- 单文件不超过 500 行（超过考虑拆分）
- 提交前跑 `swift test` 确认 105/105

### Commit 规范
推荐 [Conventional Commits](https://www.conventionalcommits.org/)：
```
feat: 添加 Anthropic Claude 平台支持
fix: 修复 GLM 5h 窗口识别错误
docs: 更新 README 添加截图
refactor: 提取 Provider 公共逻辑到 base class
test: 为 MenuBarController 添加颜色映射测试
```

### 平台 Provider 接入新平台
**必读陷阱**（来自项目踩坑经验）：

1. **必须先抓真实 raw 响应再写代码**——不要相信文档示例
2. **字段值类型可能不一致**——String / Int / Double 全检查
3. **时间戳格式可能多样**——ISO 8601 / 毫秒时间戳 / 自定义
4. **鉴权 Header 各异**——Bearer / 裸 Token / 自定义头
5. **窗口识别 ID 不一定含"5H"字样**——可能用 unit + type 组合

参考现有 3 平台 Provider：`QuotaMonitor/Services/Networking/{Kimi,MiniMax,GLM}Provider.swift`

## 发布流程（维护者）

每次发布：
1. 更新 `CHANGELOG.md`
2. 更新 `Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`
3. 跑 `swift test` 确认全过
4. commit + tag + push
5. GitHub Actions 自动跑测试
6. （可选）本地创建 .dmg + 手动发布到 GitHub Release

## 行为准则

- 尊重他人，关注问题本身
- 接受建设性批评
- 关注社区最佳利益

## 许可证

贡献的代码将以 MIT 协议发布（与项目一致）。
