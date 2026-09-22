# 构建 131 红在「滑动」路径：同一条规则只落在两条交互链路中的一条

- 日期：2026-09-18
- 触发提交：`33f00ff0`（`chore(icon): 删除 8 张旧尺寸图`）
- 失败构建：**131**（run `35309495973`）
- 相关文件：`SealUITests/ImportFlowUITests.swift`、`Scripts/verify-release-safety.py`

## 现象

构建 131 的 CI 是 `failure`，但**只有 `swift-regression` 红**：

| job | 结论 |
| --- | --- |
| `build-package` | success |
| `rork-sign-tests` | success |
| `swift-regression` | **failure** |
| `publish-release` | skipped（只在 `workflow_dispatch` 触发，正常） |

失败点唯一：

```
SealUITests/ImportFlowUITests.swift:63: error:
  -[SealUITests.ImportFlowUITests testTwoStageNavigationSupportsHorizontalSwipe] : XCTAssertTrue failed
```

即 `pager.swipeLeft()` 之后 **5 秒内「已安装应用」没出现**。
`grep -E "error: "` 里除了这一条没有任何编译错误 ⇒ 是断言失败，不是编译失败。

## 判定「抖动，不是回归」的组合证据

单独任何一条都不够，三条合起来才成立：

1. **该提交不含任何 Swift 改动**：
   `git diff --name-only d571038 33f00ff0 | grep -c '\.swift$'` = **0**
   （`git diff --stat` 显示 8 files changed, 0 insertions, 0 deletions —— 全是 PNG 删除）。
   一个只删图标的提交不可能改变 UI 行为。
2. **同一份测试代码在上一轮构建 130（`d571038`）是绿的**。
3. **同一轮里已改好的那条是绿的**：
   `testTwoStageNavigationCanBeTappedWithoutChangingHeaderAlignment`（走 `tapStage`）通过，
   只有**没改的**那条（滑动）红。

⇒ 结论：不是「新提交引入的回归」，而是**同一类断言在两条交互路径上只修了一条**。

## 根因：断言落在一个「不确定信号」上

`tapStage`（切 tab 的测试）当天已经**放弃**断言「目标页文字出现」，理由写在它自己的注释里：

> **证据（CI 实测）**：上一版把它改成「点 4 次、每次等 3 秒」**仍然失败** ——
> 失败信息是「点了「已安装，0 个」4 次之后仍未出现「已安装应用」」。
> ⇒ 说明**不是「tap 被吞掉」**，而是**点击被接受了、页面没跟着翻**。

也就是 `TabView(.page)` + `selection` 绑定在程序化改 `mode` 时**偶发不翻页**。
于是断言改落到**确定性的选中态**：`modeButton` 用
`.accessibilityAddTraits(mode == item ? .isSelected : [])` 直接反映 `mode`，
点击一旦被接受就立刻成立。

**但滑动那条路径没有人回头看一眼** —— 它还在断言同一个已被否定的信号
（`pager.swipeLeft()` 之后等「已安装应用」出现）。`apps-stage-pager` 是
`TabView(selection: $mode)`，所以两种失败模式它都有：
手势被动画吞掉，或手势被接受了却不翻页。

> 这是本仓**第 7 次**「同一条规则只覆盖两条链路中的一条」
> （前 6 次：`InstallStageTimeline`、错误映射的 `detail` 构造、安装心跳、
> `withSessionRecovery` 的证书、`updateFeatures` 的 1100 重试、门户 App ID 创建顺序）。

## 修复

`SealUITests/ImportFlowUITests.swift`：

- 新增 `swipeStage(_:to:expecting:)`，与 `tapStage` 同源 ——
  **「滑 → 等 → 没到就再滑」**（最多 4 次，每次等 3 秒），断言 `selected.isSelected`；
- 滑动测试改为：

  ```swift
  swipeStage(pager, to: .left, expecting: app.buttons["已安装，0 个"])
  swipeStage(pager, to: .right, expecting: app.buttons["待签名，0 个"])
  ```

- **它不掩盖确定性缺陷**：真坏了 4 次之后照样断言失败。

## 守卫：R28b

两条独立 check（失败信息能直接说出少的是哪一个）+ 2 个变异锚点：

| 断言 | 内容 |
| --- | --- |
| R28b-1 | `private func swipeStage(` 存在，且 `pager.swipeLeft()` / `pager.swipeRight()` 各**恰好 1 次**（只允许出现在 helper 内部 ⇒ 裸滑动会被抓住） |
| R28b-2 | `XCTAssertTrue( selected.isSelected,` 存在（用 `squash` 写成一行式，不数缩进空格） |

变异锚点：

1. 把 `swipeStage(pager, to: .left, expecting: …)` 退回 `pager.swipeLeft()`
   ⇒ 计数变 2 ⇒ R28b-1 失败；
2. 把滑动断言退回「目标页文字出现」⇒ R28b-2 失败。

⚠️ 两个锚点的期望文案都刻意写成**真实断言消息的前缀**（`any(item.startswith(expected))`）——
文案写错会报成「变异没被抓到」，看着像断言失效，其实是消息对不上。

## 验证

- 完整守卫 **PASS：423 源码断言 + 216 变异**（改前 421 + 214，各 +2）。
- 括号配平：`ImportFlowUITests.swift` 的 `{}` / `()` / `[]` 差值全为 0。
- 锚点 `old` 唯一性：新锚点与**旧锚点**在目标文件里各出现恰好 1 次
  （新代码不能把旧锚点变成多义）。
- ⚠️ **本机无 Swift 工具链** ⇒ `swipeStage` 的编译与运行只能由
  `swift-regression` 回答。这是推完要盯的第一件事。

## 本轮踩到的工具陷阱

`grep -c -- 'tapStage(app.buttons["已安装，0 个"])'` 返回 **0** ——
`[` 被当成字符类开头，正则与字面串完全不是一回事 ⇒ **假阴性**。
危险在于它看起来正是「我刚写的那行没落盘」的症状，会把人送去重写一遍已经写好的代码。
⇒ 数「刚写的代码行」一律 `grep -cF`。

## 留作候选（无证据不动）

同文件第 18 行 `app.buttons["待签名，1 个"].tap()` 也是「裸 tap + 等内容出现」的形状。
但：

- 它**等到了已稳定的「已安装应用」页才点**（初始 mode 的程序化翻页已完成）；
- 超时是 **10 秒**（滑动那条是 5 秒）；
- 最近 8 轮 CI 全绿。

而且**改成 `tapStage` 会把断言从「待签名项可达」偷换成「tab 被选中」** ——
反而丢掉这条测试真正要保的东西。⇒ 记录在案，等它真红过一次再动。
