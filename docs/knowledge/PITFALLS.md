# 常犯坑位

从 DEBUG_LOG.md 提炼，动手前必查。

## 1. 只改一处，漏了关联

- **症状**：修了 A，B 还是旧的
- **例子**：
  - 修导入抽屉图标预览，只改 ImportConfirmationView，漏了 AppSigningSheet
  - 修 iconData，漏了 decodedIconCache
  - 修 ViewModel 的缓存，漏了 ImportedAppRow 的 static 缓存
- **对策**：改任何东西，并发 grep 所有相关文件（UI、缓存、通知、持久化）

## 2. 猜而不查

- **症状**：构建失败猜是 CI 问题，实际是自己代码括号多了
- **对策**：先看日志/代码，再下结论。禁止猜测。

## 3. NSCache 的 limit 不生效

- **症状**：设了 totalCostLimit，内存还是涨
- **根因**：`setObject(_:forKey:)` 不传 cost，limit 不生效
- **对策**：手动记顺序，超了删最旧的；或传 cost

## 4. load() 会覆盖直接设置的值

- **症状**：设置了 `iconData[id]`，但 UI 不显示
- **根因**：`load()` 重建整个字典，覆盖了直接设置
- **对策**：在 `load()` 完成后再设置

## 5. 私有 struct 跨文件用不了

- **症状**：编译失败 "cannot find in scope"
- **根因**：`private struct` 只能在定义文件内用
- **对策**：改成 `internal`（去掉 private）

## 6. 守卫只查字符串，注释会误伤

- **症状**：守卫恒假
- **根因**：判"源码不得出现 X"时忘了注释里也有 X
- **对策**：先 grep 确认，或用 strip_comments
- **第二种形态（更阴：判据被注释满足 ⇒ 变异抓不住）**：
  断言查的是**裸 token**，而那个 token 在**同一个文件的注释里**也出现过 ⇒
  把真正那一行改坏之后 token 仍在、断言照旧通过 ⇒ 守卫看起来全绿，实际已经失去约束力。
  实例（2026-10-08，CI run 37764867836）：
  `Snapshot.swift` 的断言查 `"awaitingVerification" in snapshot`，而该文件第 14 行的
  **注释**里就写着这个词；把第 22 行 `return isSeal ? .installed : .awaitingVerification`
  退成 `return .installed` 之后断言仍然通过 ⇒ 变异报
  `Guard failed mutation check: E: signed artifact and installed snapshot must be separated`。
- **对策（第二种形态）**：判据要落在**那一行代码/那个表达式**上（`"return isSeal ? …" in src`），
  而不是落在「这个词在文件里出现过」上。**查 token 前先想：注释里有没有同一个词。**

## 7. 解析二进制要对着结构体定义数偏移量

- **症状**：`verify-no-lse.py --max-ios-version` 一直"通过"，却在别的目标文件上假报警
- **例子**：`build_version_command` 的 `minos` 在 **`+12`**，我写成了 `+16`（那是 `sdk`）。
  Rust 的目标文件 `sdk=0.0` ⇒ 读成 `0.0` 静默通过；asn1 的目标文件 `sdk=26.5` ⇒ 假报警
  ⇒ **这道断言从来没校验过 minOS**，两头都错。
- **根因**：Mach-O 的 load command 是纯偏移结构，凭印象写不报错、只是读错字段
- **对策**：偏移量必须贴着 `<mach-o/loader.h>` 的结构体一个个数；并且**用已知真值的产物反证**
  （拿 `RustBridge.xcframework` 试：真实部署目标 16.0 ⇒ 阈值给 16.0 应通过、
  给 15.0 必须报错。只测"通过"等于没测）。
- **同上**：`LC_BUILD_VERSION` 要连 `platform` 字段一起读，否则会拿 iOS 的 17.4 去卡 macOS 切片

## 8. 指令集守卫不能拿去扫 Rust 产物

- **症状**：拿 `verify-no-lse.py` 扫 `RustBridge.xcframework` ⇒ 报 **8980 条 LSE**
- **根因**：Rust 的 `compiler_builtins` **自带两套 outlined atomics**
  （`lse_cas1_relax.o` / `lse_swp1_acq.o` … 与对应的 LL/SC 版本），
  由 `is_aarch64_feature_detected!("lse")` **运行时分派**
  ⇒ 非 LSE 的 A10 **永远不会执行**到那些目标文件
- **对策**：这个守卫只对「单一 C/C++ 代码库、固定 `-mcpu` 基线」的产物有意义
  （如 Unicorn）。**不要**拿它扫整个 `Seal_*.ipa`，否则只会得到假报警，
  并逼人去"修"一个并不存在的问题。判据：**先确认没有运行时分派**。

## 9. 分支上"一次推送"会扇出多个 macOS 工作流

- **症状**：推一次代码，Actions 上冒出 2–3 个 run，互相取消、抢 runner
- **根因**：`perf/*` 分支上三条触发同时命中 ——
  `ios-fast.yml` 是 `push.branches` **无 paths 过滤**（任何推送都跑 30 分钟完整打包）、
  `ios.yml` 的 paths 含 `Scripts/**`、自己新加的工作流也有 push 触发
- **后果**：`cancel-in-progress: true` 会把上一次刚起来的 run 直接杀掉
  （实测 #103 只活了 **1m10s**）；而 macOS 机器池紧张时全部卡在 `queued`
  ⇒ 页面上"很多同时在"，其实**一个都没在编译**（`in_progress = 0`）
- **对策**：改动攒起来**一次性推**；给别人看状态时先看 `in_progress`，别看页面上的秒表
  （`started_at` 对 `queued` 的任务就是**入队时间**，不是开工时间）

## 10. `queued` 不等于"在编译"：`macos-26`（arm64）池会枯竭

- **症状**：Actions 页面显示 `Queued`，时间一直涨（23 分钟…），实际**一步都没跑**。
  job `conclusion=cancelled`、`steps=[]`、`runner_name` 为空、日志 blob 直接 `BlobNotFound`。
- **实测规律（2026-10-08）**：两条独立 job 都是入队后**恰好 15 分 02 秒**被掐掉
  （#102 的 `fast-ipa` 08:27:44→08:42:46；本仓 rebuild 09:06:48→09:21:51），
  且都拿不到 runner ⇒ 不是编译失败，是**排队阶段就被回收**。
- **根因**：GitHub-hosted **macOS 的机器池是按「镜像 + 架构」分的**，
  单个池子会单独枯竭。当天 `macos-26`（arm64）枯竭，而**同一个镜像**的
  `macos-26-intel`（x86_64）完全空闲 —— 两者都报 `Image: macos-26`，
  Xcode 26.0–26.6 / cmake 齐全，只是硬件不同。
- **判别手法（30 秒、零副作用）**：往一个**临时分支**推一个只有 `runs-on` + `sw_vers` 的
  矩阵探针（`macos-26` / `macos-15` / `macos-15-intel` / `macos-26-intel`），
  几条腿**几秒内**分配成功就说明那条池子是活的；用完把分支删掉。
  （推临时分支不会掀 `ios-fast.yml`：它的 `push.branches` 只列了 `main` 与本分支。
  但推**本分支**时一定会触发它，推完立刻 `gh run cancel`。）
- **对策**：`runs-on` 换到活着的池子。**前提是先判断"宿主架构对本次构建有没有影响"** ——
  这一步很容易想当然，本仓已经踩过一次：
  - **xcodebuild 用户**：`-sdk iphoneos -destination 'generic/platform=iOS'`（设备构建）与宿主架构无关，
    **可以**走 Intel 池子。`ios-fast.yml` / `ios-release.yml` 的 IPA 打包属于这类。
  - **第三方构建脚本自己调 `configure`/autoconf**：⚠️ **不能**想当然。这类脚本常常
    **不把 `-arch` 转发给嵌套的 configure**，于是 configure 的「能否生成可执行文件」探测
    按**宿主机架构**编译（platform 能由 `-isysroot` 推出来，**arch 推不出来**）
    ⇒ Intel 宿主得到 `x86_64-apple-ios`，而 iPhoneOS SDK 没有 x86_64 切片 ⇒ 链接失败。
    **实例**：Unicorn 的 `CMakeLists.txt:384-392` 调 `qemu/configure` 时 `--extra-cflags`
    里只有 `-isysroot`（`${CMAKE_C_FLAGS}` 仅在 `UNICORN_FUZZ=ON` 时才拼进去，默认 OFF），
    实测在 `macos-26-intel` 上报
    `qemu/configure failed (1): cannot build an executable (is your linker broken?)`
    ⇒ **必须 arm64 宿主**。判据：**先读构建脚本，别只看自己传的 flags**。
  - **要跑 iOS 模拟器** ⇒ 模拟器按宿主架构跑，Intel 宿主需要 x86_64 模拟器切片；而本仓 `RustBridge`
    只出了 `aarch64-apple-ios-sim`（见 `rebuild-rustbridge-ios16.yml`），**没有 x86_64**
    ⇒ `ios.yml` 的 `swift-regression` **必须留在 arm64**，不能换 Intel。
- **别混淆**：public 仓库的标准 runner **免费且不限量**，账号级 macOS 并发上限是 **5**；
  这两者与"某个镜像池暂时没机器"是**三件独立的事**。查之前先分清是哪一件。

## 11. 两阶段提交的"分支缺口"：没有草稿就什么都不做

- **症状**：同版本续签 / 自更新失败之后，记录里的 profile 身份与有效期**永远**停在签名阶段的
  乐观值；界面显示一个设备上并不存在的到期日，用户直到应用被吊销都收不到提醒。
- **根因**：两阶段提交重构把「按运行包结算 profile 身份」整段挪进了
  `if existing.pendingSignedSnapshot != nil` 分支 ⇒ **没有草稿时整个对账空转**。
  但「没有草稿」恰恰是最需要兜底的两种情形：
  ① 自更新失败（有待安装源但候选没落盘）；
  ② 用户在别处重签了 Seal 再装回来 —— **版本号不变**，只比版本号看不出来（这正是 R07 要防的）。
- **对策**：写这种 `if 有草稿 { … }` 时，必须同时回答**「没有草稿时谁来兜底」**。
  本仓的落地形态：草稿去留按「回滚判据」决定；**标量身份**（profile UUID / 有效期 / 证书）
  统一由「运行包 = 设备现实」最后覆盖。
- ⚠️ **但"运行包永远对"不成立**：profile-only 续签只注入新描述文件、**不重装 App**，
  `Bundle.main` 里还是旧的 embedded profile ⇒ 无脑回盖会把刚续的 profile 打回原地。
  判据只能是「运行包报出的有效期**更晚**」或「**存在待安装的自更新源**」这类**能区分情形**的标记，
  不能只看「记录和运行包不一样」。
- **另一面**：派生状态（如「本机证书状态」）的输入是记录字段，那就必须**输入变一次算一次**
  （记录换了、密钥读回了各算一次）。只在 `load()` 里算一次 ⇒
  颜色（读记录）已经变了、「需重新签名」文案（读快照）还停在旧序列号上，**两者不同帧**。
  2026-10-08 真机：重新续签 + 安装替换 Seal 后点进详情页就是这么个现象。
- **死参数也是同一个病的余波**：行为改了（Seal 永不进严格保留集合），
  为旧行为服务的参数（`profileKeepMap(sealProfileUUID:)`）会留在签名里，
  后人一看就会以为它还在起作用。**改行为时把配套的入口一起删掉。**

## 12. CI 里大量 `cancelled` 会造成"假静默"：别拿"上一次 run"当基线

- **症状**：一个**既存**的红色回归被误判成"本轮改动引入的"，于是去改本来没问题的代码。
- **实例（2026-10-08）**：`swift-regression` 报 7 个 UI 用例红。真凶是
  **2026-10-07** 引入的开屏协议门控（`AgreementOnboardingView` + `SealApp.agreementAccepted`）：
  它把**整个** `RootTabView` 挡在协议页后面，而 `SealUITests` 直接找根界面元素 ⇒ 全部停在协议页。
  但 2026-10-05 之后 100 次 run 里 **70 次 `cancelled`**（被新推送顶掉，job 根本没跑完），
  这个红点直到 2026-10-08 才第一次真跑完并暴露。
- **对策**：
  - 判断"是不是我改坏的"，基线要取**上一次真正跑完（`completed`）的 run**，不是"上一次 run"。
    本仓可直接用：`gh run list --workflow=iOS --limit 100 --json databaseId,conclusion`
    数一下 `cancelled` 占比 —— 占比高就说明你的历史基线基本是空的。
  - 报错要**逐字比对**：两次 run 的「文件:行号 + 消息」完全相同 ⇒ 基本可判定与本次改动无关。
  - 更要看**全局形态**：同一次 run 里"单测全绿、只有 UI 用例红"是个强信号 ——
    业务逻辑没问题，问题在"界面根本进不去"这一层。
- **推论（比本条更重要）**：给界面加**前置门**（协议 / 登录 / 引导 / 新手教程）时
  **必须同步 UI 测试**，否则它会**静默换掉整套 UI 用例的语义** ——
  所有用例都变成"门控用例"，而它们各自的断言只是"超时失败"，看不出真正原因。
  正确形态是**两类用例分工**：既有用例用显式启动参数**越过**门（快、确定），
  再单独留一条用例**真正覆盖门本身**（含"同意之后确实进得去主界面"，
  只断言"按钮消失"会把"门关了但主界面也没起来"这种死锁放过去）。
- ⚠️ 越过门用的参数要**显式**（如 `--ui-testing-agreement-accepted`），
  **不要**用「`--ui-testing-` 前缀匹配」—— AGENTS.md §3 禁止前缀与数字区间：
  前缀规则会让"哪些参数能开门"不可枚举，下一个加 UI 测试的人无从自查。
- **"未同意/未登录"这种前提不要靠模拟器里攒下来的 `UserDefaults`**：
  那样用例会随执行顺序、模拟器是否复用而时红时绿。
  用 `-<key> <value>` 启动参数钉进 `NSArgumentDomain`（优先级高于持久域、且不落盘）才确定。

## 13. 判据里"版本号比较"是个筛子；返回值的"契约"被借用就会静默写回

两条独立的坑，2026-10-08 同日在一个函数上叠着爆，所以一起记。

### 13a. 拿"版本号变了没"当唯一判据，同版本场景就是筛子

- **实例**：`SelfAppRegistrar.reconcileSealRecordFromRunningBundleIfNeeded` 判断
  "候选包到底有没有落到设备上"用的是 `version != 运行版本`。
  **同版本**续签（换 profile 但版本号不变，R07 的题面）一旦自更新失败，两边版本**完全相同**
  ⇒ 判据恒 false ⇒ 签名阶段写进草稿的候选身份被 `commitPendingSnapshot()` **转正成顶层真相**。
  记录里从此是一个设备上不存在的有效期 —— 用户直到被吊销都收不到提醒。
- **正确形态**：**知道答案的那一层要显式说出来**，别让下游从侧面推。
  现在加的是 `candidateConfirmedNotInstalled: Bool = false`：
  `.closeAsNotInstalled` 分支**刚刚确认**候选没装成，就直接告诉结算函数；
  其余调用点不知道候选去向，保持默认。判据变成
  `candidateConfirmedNotInstalled || (有待安装源 && 版本不一致)`。
- **推广**：凡"从 A 能否推出 B"的判断，先列一遍**所有让 A 都不变但 B 不同**的情形。
  profile-only 续签 = 版本不变但设备上有新 profile；同版本自更新失败 = 版本不变但设备上没有新 profile。
  两者对"版本号"这个输入**完全一样**，却要求相反的动作 ⇒ 版本号永远不可能同时满足它们。

### 13b. `return false` 同时被当成"不算成功"用 ⇒ 调用方不重读 ⇒ 旧快照写回

- **实例**：`reconcileSelfReplacement` 的返回值契约写在注释里：
  "返回**是否推进了记录**，调用方在结算后**必须重新读取记录**，避免用旧快照覆盖刚确认的真实身份。"
  而 `.closeAsNotInstalled` 分支结尾写的是 `return false` —— 作者的意图是"这轮**不算成功**"
  （业务语义），但返回值承载的是"记录**没变**，你别重读"（机制语义）。
  结果：记录明明被回补推进了，调用方却不重读，手上那份旧快照里
  **还带着刚被丢弃的 `pendingSignedSnapshot`**，被后面几轮对账**原样写回库** ——
  刚丢弃的候选身份当场复活。
- **教训**：
  - 一个返回值只能承载**一个**语义。要表达"不算成功"，就用另一条通道
    （这里已经有 `settlePendingBatchSealResult(to: .failed)` 与 `SEAL-SELF-111` 日志）。
  - 注释里写了契约就当契约读：改返回值前先看**谁在消费它**。
  - "算一次、存一份、后面还会再算几次"的链路，每次都要问：**手上这份还是最新的吗？**
    在内存里持有一个可被别处改写的记录副本、并在同一个函数里多轮对账 = 沉默写回。
