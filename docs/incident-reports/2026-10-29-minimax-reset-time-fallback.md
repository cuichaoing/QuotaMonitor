# MiniMax 重置倒计时恒为「4 小时 59 分」— 根因 + 修复

> 报告日期：2026-10-29
> 编号：BUG-2026-10-29-01
> appVersion：1.1.0 → 修复 v1.1.1
> 阶段：完成（代码已实现 + 回归测试 + 实机验证）
> 处理流程：用户反馈 1 阶段 HITL（用户明确要求先修准确性，再做衍生功能）

---

## 0. 结论摘要

| 维度 | 结论 |
|------|------|
| 性质 | 字段名写错导致**永远走兜底值**，倒计时与服务端窗口无关 |
| 现象 | MiniMax 倒计时恒显示「4 小时 59 分 · 抓取时刻+5h」 |
| 实际 | 服务端窗口真实结束时刻在 `model_remains[i].end_time`（毫秒时间戳） |
| 修复 | 按 `end_time` → `remains_time` → 旧字段 → `now+5h` 四级优先取真实重置时刻 |
| 附带 | 接上此前完全没用的周窗口（`weekly_end_time` + `current_weekly_remaining_percent`） |
| 版本 | v1.1.0 → **v1.1.1** |

---

## 1. 现象（用户实测）

用户反馈：

> 我实际验证 MiniMax 的剩余时间是 1 小时 56 分，我此时此刻是 16:24，
> 预计今天下午 18 点左右就会恢复额度。但我点开窗口，上面显示的却是「重置于 4 小时 59 分，21:24」。

**关键特征**：显示的时间点 = 用户观察时刻 + 5 小时，误差恒定且与真实窗口无关。
（服务端窗口 18:00→23:00 时，App 显示的却是 21:24 这种"抓取时刻+5h"的值。）

---

## 2. 根因

### 2.1 字段名不存在 → 100% 落到兜底

原实现（`MiniMaxProvider`）：

```swift
let resetAt = KimiProvider.parseResetTime(json["resetTime"])
    ?? KimiProvider.parseResetTime(primary["interval_end_time"])
    ?? Date().addingTimeInterval(5 * 3600)   // ← 永远走这里
```

两个候选字段在真实响应里**都不存在**：

- 顶层 `resetTime` —— MiniMax 的 Coding Plan 接口没有这个字段（那是 Kimi 的字段名，被误植过来）
- `interval_end_time` —— 真实字段叫 `end_time`，少了前缀

`KimiProvider.parseResetTime` 只认 ISO8601 **字符串**，而 MiniMax 给的是**毫秒时间戳**，
即便字段名写对也解析不出来。两条路都堵死，结果就是每次都拿 `now + 5h`。

### 2.2 为什么之前没被发现

v1.0.1 重写 MiniMaxProvider 时（`current_interval_remaining_percent` 反算已用率那次），
重点全在**百分比语义**上，重置时间当时是"先用兜底值占位，未来根据真实响应再调整"——
这个 TODO 一直没人碰，而"兜底值恰好长得像个合理的时间"让它潜伏了 4 个月。

---

## 3. 真实响应（2026-10-29 实测抓包）

```json
{
  "model_remains": [{
    "model_name": "general",
    "start_time": 1793268000000,          // 当前 5h 窗口开始（ms）
    "end_time": 1793286000000,            // 当前 5h 窗口结束（ms）← 真正的重置时刻
    "remains_time": 12093519,             // 窗口剩余毫秒（与 end_time 互证）
    "current_interval_remaining_percent": 99,
    "weekly_start_time": 1792972800000,   // 周窗口开始
    "weekly_end_time": 1793577600000,     // 周窗口结束（ms）
    "weekly_remains_time": 303693519,
    "current_weekly_remaining_percent": 100
  }]
}
```

换算验证：`end_time - start_time = 18000000 ms = 5h`（窗口长度正确），
`end_time - remains_time ≈ now`（两个字段自洽）。

---

## 4. 修复

```swift
let resetAt = Self.epochMillis(primary["end_time"])              // 绝对时间，优先
    ?? Self.relativeMillis(primary["remains_time"], from: now)     // 相对时间，次选
    ?? KimiProvider.parseResetTime(json["resetTime"])              // 兼容旧字段
    ?? now.addingTimeInterval(5 * 3600)                             // 兜底
```

- `epochMillis`：兼容 13 位（毫秒）与 10 位（秒）
- 周窗口同步接入 → `ProviderQuota.weeklyWindow`（弹窗多一行「7d」）

---

## 5. 回归测试

`QuotaMonitorTests/MiniMaxProviderTests.swift`（用真实响应做夹具）：

| 用例 | 断言 |
|------|------|
| `testResetTime_usesServerEndTime_notNowPlusFiveHours` | `resetAt == end_time`；**反向断言不等于 now+5h** |
| `testResetTime_fallsBackToRemainsTime` | 无 `end_time` 时用 `remains_time`（1 小时后） |
| `testWeeklyWindow_parsedFromRealFields` | 周窗口结束时刻与已用百分比正确 |

`swift test` → 160/160 通过。

---

## 6. 顺带核对：另外两家没问题

| 平台 | 重置时间来源 | 是否真实服务端时间 |
|------|-------------|-------------------|
| Kimi | `limits[0].detail.resetTime`（ISO 8601 字符串） | 是 |
| GLM | `data.limits[i].nextResetTime`（毫秒时间戳） | 是 |
| MiniMax | `model_remains[i].end_time`（毫秒时间戳，v1.1.1 修正后） | 是 |

---

## 7. 教训

1. **兜底值不能长得像真值** —— `now + 5h` 在 5h 滚动窗口场景下"看起来合理"，
   但它永远错。兜底应当可被测试识别（本例：回归测试显式断言"不等于 now+5h"）。
2. **字段名不通用** —— 一个 Provider 的字段名不能想当然套到另一个 Provider，
   `resetTime` 是 Kimi 的，不是 MiniMax 的。
3. **按项目规约先抓真实响应**（CONTRIBUTING「必读陷阱」第 1 条）：
   本次修复第一件事就是打真实接口打印全部字段，5 分钟定位，
   而不是猜字段名改代码。
