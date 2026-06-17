# Security Policy

## Supported Versions

| Version | Supported          |
|---------|--------------------|
| 1.0.x   | Yes                |
| < 1.0   | No                 |

## Reporting a Vulnerability

**请不要在 GitHub Issue 公开报告安全漏洞。**

如发现安全漏洞（例如 Keychain 泄露路径、签名校验绕过、API Key 误存日志等），请通过**私有渠道**联系维护者：

- 邮件：[请在此填入维护者邮箱]
- GitHub Security Advisories：https://github.com/你的用户名/QuotaMonitor/security/advisories/new

我们会在 7 个工作日内回复，48 小时内评估严重性，并在修复后发布补丁版本。

## 数据处理原则

- **API Key**：仅存储于 macOS Keychain（`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`），从不写日志、不上传到任何服务器
- **Bark 推送**：可选功能，设备 Key 由用户主动配置
- **网络请求**：仅向 Kimi / MiniMax / 智谱 GLM 三大平台官方 API 发起（端点见 README）
- **遥测**：本应用无任何第三方分析、统计、追踪 SDK

## 已知安全特性

- 状态栏数字颜色由本地阈值计算，无任何远端策略
- 所有 Provider Key 在显示前需通过 macOS 身份验证（Touch ID / Apple Watch / 系统密码）
