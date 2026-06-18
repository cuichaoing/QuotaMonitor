# Bug 反馈处理 SOP

> 版本：v1.0 · 2026-06-18
> 适用：用户提交任何 bug 反馈时的标准处理流程
> 关联：`CLAUDE.md`（项目主控指令、陷阱表）

---

## 0. 核心原则

- **系统化调试**：先找根因，禁止随机修（`superpowers:systematic-debugging`）
- **TDD**：先写失败测试，再实现（`superpowers:test-driven-development`）
- **验证先于断言**：拿命令输出说话，不口头宣称"修好了"
- **2 阶段 Human-in-the-loop**：两个确认节点，缺一不可

---

## 1. 流程总览

```
用户提 bug
   │
   ▼
【阶段 1 · 分析与计划】
   唤醒协议 → 系统化调试 Phase 1（根因调查，不提修复）
   → 产出根因分析报告（Markdown，docs/incident-reports/，Marked 打开）
   → ◆ 节点 1：等用户拍板「可以改」
   │
   ▼ （用户拍板后）
【阶段 2 · 执行与提交】
   TDD 改代码 → swift test 验证 → bump 版本 + CHANGELOG → commit
   → ◆ 节点 2：汇总改动+测试结果，等用户说「确认做吧」
   │
   ▼ （用户确认后）
【4 步落地操作】
   1. 登记 bug 号
   2. 确认 CHANGELOG
   3. 替换本地 /Applications
   4. 提交 GitHub
```

---

## 2. 阶段 1：分析与计划

### 2.1 唤醒协议（开口前先静默读）

1. `docs/HANDOFF_v1.0.2_github_open_source_2026-06-17.md`（**注意真实文件名带 `_github_open_source`**，CLAUDE.md 速查表里的短名已失效）
2. `CHANGELOG.md`
3. `README.md`
4. `USER_GUIDE.md`

> 读时核对版本一致性：CLAUDE.md 的版本号、测试数等元信息可能滞后（本项目已多次出现）。

### 2.2 系统化调试 Phase 1（根因调查）

- 读错误信息、复现、查最近改动、追数据流
- **禁止在此阶段提任何修复**，只产出根因
- 多组件系统：在每个边界加诊断证据，定位失败层

### 2.3 产出：根因分析报告

- 落盘 `docs/incident-reports/<日期>-<bug 简述>.md`
- 用 Marked 打开供用户审阅（B 类文档：仅本机打开，不同步 iCloud）
- 内容含：现象、证据链、根因（分层）、修复方案（含改前/改后代码）、验证计划、待确认决策点

### ◆ 节点 1

等用户拍板「可以改」 + 确认决策点（如取整方向、文档位置等）。**未拍板前不动代码。**

---

## 3. 阶段 2：执行与提交

### 3.1 开工（用户拍板后）

1. TDD：写失败测试 → 看红 → 最小实现 → 看绿 → 重构
2. 改 UI / 其他消费层
3. `swift test` 全过、无回归
4. bump 版本号：`QuotaMonitor/Resources/Info.plist` 的 `CFBundleShortVersionString`
5. 更新 `CHANGELOG.md` 顶部新增版本段
6. 写 memory（若涉及流程/陷阱更新）+ 更新本 SOP（若流程演进）
7. `git add -A && git commit`（让 working tree 干净，为 `release.sh` 的 clean 检查做准备）

### ◆ 节点 2

汇总：改了哪些文件、测试结果（贴命令输出）、版本号、CHANGELOG。等用户说「确认做吧」。**未确认前不替换 `/Applications`、不推 GitHub**（对外 / 难撤销动作必须二次确认）。

---

## 4. 节点 2 确认后的 4 步落地操作

> 对应用户定义的执行标准。

### 步骤 1：登记 bug 号

- 分析报告已在 `docs/incident-reports/`（文件名含日期）
- CHANGELOG 版本段记录该 bug
- 如需独立编号，建议格式 `BUG-YYYY-MM-DD-NN`

### 步骤 2：确认 CHANGELOG（阶段 2 已写，此步复核）

### 步骤 3：替换本地 `/Applications`

```bash
cd <PROJECT_ROOT>
swift build -c release
cp .build/release/QuotaMonitor build/QuotaMonitor.app/Contents/MacOS/QuotaMonitor
cp QuotaMonitor/Resources/Info.plist build/QuotaMonitor.app/Contents/Info.plist
codesign --force --deep --sign - build/QuotaMonitor.app

# 先退出旧进程，否则覆盖后会跑旧实例
osascript -e 'tell application "QuotaMonitor" to quit' 2>/dev/null; pkill -x QuotaMonitor 2>/dev/null

# 覆盖安装 + 启动
# [!] 必须先 rm：若 /Applications/QuotaMonitor.app 已存在，cp -R 会把源「嵌套」进去
#     变成 /Applications/QuotaMonitor.app/QuotaMonitor.app，旧的 Info.plist 不被替换
#     （v1.0.6 实测踩坑：版本号停在旧值）。先删再 cp。
rm -rf /Applications/QuotaMonitor.app
cp -R build/QuotaMonitor.app /Applications/QuotaMonitor.app
open /Applications/QuotaMonitor.app
```

> 本地 build 与 CI 产 dmg 都是 ad-hoc 签名（`codesign --sign -`），互相覆盖无签名冲突。

### 步骤 4：提交 GitHub

```bash
./scripts/release.sh <version>     # 例：1.0.6
# 自动：swift test → 检查 clean → bump Info.plist → commit + tag v<version> → push → watch CI
# CI（release.yml）自动：build + test + 产 dmg + 发 GitHub Release
```

> 注意：`release.sh` 第 2 步检查 working tree 干净——所以 CHANGELOG / 代码改动必须**先 commit**，否则脚本退出。

---

## 5. 关键约束（不可违反）

| 约束 | 说明 |
|------|------|
| 节点 1 前不动代码 | 分析阶段只读不写 |
| 节点 2 前不替换 app / 不推 GitHub | 对外动作必须二次确认 |
| 中文交流、严禁 Emoji | 用 [OK] [X] [!] [>] 等文字符号 |
| 隐私敏感 | API Key 走 Keychain，显示需 Touch ID / 系统密码 |
| 遵守陷阱表 | 见 `CLAUDE.md` 必记陷阱（objectWillChange 时序、GLM 鉴权等） |

---

## 6. 示例：v1.0.6 状态栏与 Popup 不一致

- 阶段 1 报告：`docs/incident-reports/2026-06-18-menubar-popup-percent-mismatch.md`
- 双层根因：`objectWillChange` 时序滞后 + 取整不一致
- 修复：`store.$snapshots` + `ProviderQuota.displayPercent`
- 测试：`ProviderQuotaTests` 四舍五入边界
- 此 bug 同时是陷阱表「objectWillChange 时序」的第二个实例（首个是 v1.0.2 阈值 slider）
