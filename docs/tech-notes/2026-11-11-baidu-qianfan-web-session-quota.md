# 百度千帆 Token Plan 网页订阅配额监控接入 — 技术笔记

> 日期：2026-11-11
> 版本：v1.3.0 引入
> 代码：`QuotaMonitor/Services/WebSession/{BaiduSessionManager,BaiduUsageParser}.swift`
> 状态：已实机验证（用户侧出数字）

---

## 0. 为什么需要一条新链路

前五个平台里三个是 **API Key 型**（Kimi / MiniMax / 智谱 GLM，走 Keychain + 打官方 API），
一个是 **AK/SK 签名型**（火山方舟，控制面 OpenAPI），一个是 **网页会话型**（Gemini）。
百度千帆 Token Plan 属于第四种形态：**包月订阅制 + 无公开用量接口**。

用户提供的凭证是 `bce-v3/<AccessKeyId>/<SecretKey>`（百度智能云 AK/SK 对），
所以第一反应是「那大概能调控制面 OpenAPI」——**穷尽排查后确认不能**：

| 探查面 | 手段 | 结果 |
|---|---|---|
| 公开 API 文档 | 抓取全部 **424 个页面**标题 + 正文 | 只有「查询免费实例额度」（那是 vdb 向量库的）与「服务调用请求级用量详情」（异步导 CSV，且需 serviceId）。**无套餐余量接口** |
| 数据面 | 7 个 `/limits` `/usage` `/quota` 候选路径 | 全 404（网关是 FastAPI，返回 `{"detail":"Not Found"}`） |
| 控制面 OpenAPI | 实现 BCE V1 签名，盲探 **95 组** Action×Service | 全 404；签名本身有效（返回路由层错误而非鉴权错误） |
| 社区参照实现 | CC Switch 的 `coding_plan.rs`（火山当初就是照它做的） | Token Plan 模板覆盖 Kimi/GLM/MiniMax/火山/OpenCode Go/Command Code，**不含千帆** |
| 千帆控制台前端 | 下载 SPA bundle 找接口 | 主 bundle 无 tokenplan 代码（页面在按需加载的 chunk 里）；路由串 `/resource/token-plan-enterprise/my-subscription` |

**结论**：套餐余量只存在于登录后的控制台网页 → 只能走网页会话型（与 Gemini 同构）。

---

## 1. 指标模型：包月总量制，不是 5 小时窗口

这是与 K/M/G/Z/V 最大的差异。控制台「我的订阅」页（2026-11-11 实抓）长这样：

```
余量
2026-12-11 14:51:08 重置
限时恢复额度
95.06%
剩余665,463,337 / 总量700,000,000 Token
```

于是映射到统一模型：

| 统一模型字段 | 取值 |
|---|---|
| `total` | 700,000,000（总量 Token） |
| `used` | 总量 − 剩余 = 34,536,663（**页面给的是「剩余」，要反过来算已用**） |
| `usedPercent` | 4.93%（状态栏按已用百分比上色，与其他平台口径一致） |
| `resetAt` | 2026-12-11 14:51:08（**北京时间**，解析时必须显式指定时区） |
| `displayName` | 「月」（非滚动窗口，是订阅到期日） |
| `weeklyWindow` | 无（只有月套餐一个窗口） |

**注意 `used` 的方向**：页面显示「剩余 95.06%」，而 QuotaMonitor 全局语义是「已用百分比」，
两者差一个取反。忘了取反就会出现「已用 95%」→ 一上来就红色告警。

---

## 2. 抓取链路

```
登录窗（可见 WKWebView，1100×760）
  └─ 用户登录百度账号 → 落回 console.bce.baidu.com 域
       └─ 轮询等待「余量」区块渲染出数字 → 判登录成功 → 落盘 cookie → 关窗

抓取窗（隐藏 WKWebView，480×360，位置挪到屏幕右缘外）
  └─ 加载 console.bce.baidu.com/qianfan/resource/token-plan
       └─ 轮询执行 JS 提取脚本 → 切「余量」区块原文 → Swift 端解析
```

**关键设计决策：JS 只切原文，解析放 Swift。**
初版把「剩余 X / 总量 Y」的中文正则写在 JS 里，页面文案一变（插「Token」、全角斜杠、
数字带单位）就失配，且失败时**丢掉原文无从诊断**。改为 JS 输出区块原文（≤600 字符），
Swift 端解析 —— 可单测、失败时原文能随报错带出。

---

## 3. 与 Gemini 链路的差异清单

| 维度 | Gemini | 百度千帆 |
|---|---|---|
| 登录判据 | 认证 cookie（`SID`/`SSID`/`HSID`/`APISID`/`SAPISID`/`ACCOUNT_CHOOSER`） | **页面渲染出用量**（cookie 名不可靠，见下） |
| 登录后 | 自动关窗 | 自动关窗（同样要等页面真的渲染出内容再关） |
| 指标 | 当前窗口 + 7d 两个窗口 | 单个月窗口 |
| 页面 | `gemini.google.com/usage` | `console.bce.baidu.com/qianfan/resource/token-plan` |
| 抓取窗口 | 同样需要放屏幕内 | 同上 |

**「不按 cookie 名判登录」**：`BDUSS` 是**百度通行证域**（passport.baidu.com）的 cookie，
而 `console.bce.baidu.com` 用的是另一套（`bce-session` / `bce-long-term-sessionid` /
`bce-passport-stoken` / `bce-ctl-client-cookies`）。实测 cookie 落盘后共 52 个，
按域分布很散。判据统一改成**页面证据**（渲染出用量 / 已离开登录页且有百度 cookie）。

---

## 4. cookie 持久化（非沙盒 App 必做）

macOS 上**非沙盒** App 的 WKWebView **不持久化 cookie**：
`~/Library/WebKit/app.quotamonitor/WebsiteData/Default/Cookies` 恒为 **0 字节**，
localStorage 同样为空。后果是每次重启 App 都要重新登录百度（用户实际经历了 4~5 遍）。

解法是不依赖 WebKit 的磁盘策略，自己来：

- 抓取/登录成功后 → `httpCookieStore.getAllCookies` → 只留 `*.baidu.com` →
  导出 JSON 到 `~/Library/Application Support/QuotaMonitor/baidu_cookies.json`
- 每次 `fetchQuota()` 前 → 读回 → `httpCookieStore.setCookie` 灌回（幂等）
- 「退出登录」时一并删掉该文件

恢复时只还原必要字段（name/value/domain/path/secure/expires），
不直接序列化 `HTTPCookie.properties`（Date 字段过不了 JSON）。

---

## 5. 未来可能的替代路径

千帆控制台用的是**同源 REST 接口**（`/api/qianfan/charge/user/info`、
`/api/iam/account/quota`、`/api/account/get_myaccount` 等），而非 OpenAPI。
实测 hook 全量扫描（fetch + XHR 响应体，关键词 `余量/剩余/665463337/700000000/remainQuota/…`）
**未命中套餐余量接口** —— 可能数据在微前端 iframe 内、或由前端计算得出。

若将来找到该接口，可把千帆改成「cookie + URLSession」直连（与 K/M/Z 同款），
彻底摆脱 WebView（也就彻底摆脱钥匙串弹窗与离屏渲染问题）。
