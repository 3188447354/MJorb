# DEBUG_LOG

> 复盘记录：现象 → 根因 → 修复 → 涉及文件 → 验证状态。新条目追加到「历史记录」顶部（最新在前）。
> 动手前先查阅下方「常犯坑位」，避免同类问题重复发生。

---

## 常犯坑位

- **证书序列号跨来源比对必须归一化**（strip leading zeros），否则会用不同表示误判「证书被轮换/不在授权列表」。
- **进度条卡 % 是阶段切换时机问题，不是进度值本身**。排查进度显示别盯着百分比，要看阶段切换回调。
- **`rg` 查询带再加工时，行号输出用 `-n`，别拿 `-r` 当行号**。
- **证书轮换 / 证书自动清理两条撤销路径都要各自守住「无法确认 Seal 真实签名证书就禁止撤销」**，缺一条就会误删 Seal 自己的命根子证书。
- **iLoader 等第三方签名工具产出非标准签名结构/描述文件**，Seal 的 `AppBundleSigningIdentityReader` 可能读不出真实 CMS 签名者，会连锁触发 SEAL-CERT-232 / SEAL-SELF-105，只能电脑覆盖安装兜底。**允许放宽的只有「CodeDirectory 全量哈希校验」（第三方改结构导致哈希对不上属正常），身份识别仍必须落在「一致 signer serial」+ `signerNotAuthorizedByProfile`（serial 须在描述文件授权证书内）双校验上；任何「连 signer serial 都读不出仍继续签名」的弱化都是明令禁止的**——那会直接导致误删 Seal 自己命根子证书。
- **改动核心语义（签名/证书/续签）时，老的同名单测往往断言的就是正要被替代的行为**。改实现后云构建的 `swift-regression` 就会在这些测试上红（exit 65），而 `build-package` / `rork-sign-tests` 仍绿。动手前先 grep 相关 `SealTests/**/*Tests.swift` 核对断言，并与实现改动同步更新到新设计，避免「改实现 → 推一次 → 只有这里红 → 再修测试推一次」的双倍等待。
- **`verify-release-safety.py` 的守卫会按字符串断言 UI 结构**。改动证书页/证书展示相关代码时，先跑一遍守卫（Windows 上也能跑），它会直接点名「哪条断言 + 哪个变异锚点」失效；改动是有意为之就同步更新守卫（连同变异锚点），**不要为了过守卫把实现写回去**。
- **同一实体的两处 UI 展示必须同源**。同一张证书的「关联了哪些 App」曾出现行标签用 `associatedApps`（含扩展 target）、下方清单用 `affectedApps`（只看顶层 serial + `state == .installed`）两套判定，结果自相矛盾（标签说在用、清单说暂无），Seal 自身因 `belongsInInstalledList` 恒为真且 `state` 不一定是 `.installed` 尤其容易被漏掉。**展示口径要复用同一个函数**；撤销影响评估仍走更严的 `affectedApps`，两者不可合并。
- **私有 selector + `guard responds(to:) else { return }` = 静默 no-op**。Seal 自续签的「回主屏」原来只有一条 `perform("suspend")`，不响应时什么都不做，最后由 installd 杀进程 —— 用户观感就是「闪退」。凡是靠私有 API 实现的可感知行为，都必须有兜底路径（此处是 `UIControl().sendAction(_:to:for:)` + `exit(0)`），不能静默返回。
- **「卡很久」的排查方向是「该并行的被串行等了」，不是「超时太长」**。签名/续签曾卡在「正在连接设备」很久：`SigningCoordinator` 里已经做了隧道与签名并行，但 `AppsViewModel.runSigning` 在更早的位置 `await refreshSigningChannel()` 把整段诊断又同步等了一遍，并行化对首个调用完全失效。**改并行化时要顺着调用链往上游找还有没有第二次同步等待**；并发启动同一通道还要在通道层做单飞合并，否则重复诊断、耗时翻倍。
- **批量入口解阻塞的前置条件是「下游有熔断」**。`startBatchRefresh` 的前置 `await refreshSigningChannel()` 看着像冗余，其实是保护：`MinimuxerInstallChannel.startOnce` 失败时**不写缓存**，去掉等待后通道不可用会让 N 个 App 各跑一遍 75s 诊断（N×75s）。**要解阻塞必须先在通道层加失败熔断**（失败后 60 秒窗口内直接抛同一错误），并且熔断只能挡「同一轮批量内部」的连续调用 —— 用户发起的会话（`runSigning` / `startBatchRefresh` / `refreshSigningChannel`）都要显式 `clearFailureCooldown()`，否则用户修好 VPN 再点也被秒拒，看起来像 Seal 坏了。
- **只在 extension 里给方法默认实现 = `any Protocol` 静态派发到空实现**。`clearFailureCooldown()` 若只写在 extension，`any InstallChannel` 会调用默认空实现，具体实现的覆写永远不执行，表现是「用户手动重试一直被拒」而守卫全绿。**凡是需要动态派发的行为都必须声明为 protocol requirement**（本仓 `install(onProgress:)` 已踩过一次，现已加守卫断言锁住）。
- **Apple 免费账号的 `1100 session expired` 多数是「限流被掐断」，不是真过期**。抖音（主 App + 8 扩展 = 9 个 bundle ID）在 App ID 阶段连发 9 次 `addAppID` + 9 次 `updateFeatures`、再连发 9 次描述文件申请，二十余次密集请求会触发 Apple 掐断会话。**判据：报错前 1–3 秒若有「证书决策」成功，说明 session 服务端仍有效**（同一账号几分钟前刚成功签过别的 App 也是同一证据）。此时引导用户「重新验证 Apple ID」是死循环 —— 重新登录后密集请求再次触发限流。对策是请求节流 + 对 1100 退避重试，且 **App ID 阶段的 1100 文案必须与 account 阶段分开**（前者给「稍后重试」，后者才给「去重新验证」）。
- **错误分类禁用子串匹配**。`diagnostic.contains("1100")` 会把形如 `com.example.app1100` 的 Bundle ID 报错误判成「会话过期」，把「Bundle ID 不可用」错报成「登录过期」。只认错误码 + 官方英文文案。
- **统计字段的文案要跟字段语义对齐**。`usedBundleIDCount` 是「已注册存活数量」，却被渲染成「N 个可用 App ID」——日志里 `10 个可用 App ID` 的真实含义是**已用满 10 个**。这直接导致用户「id 有足够的名额」的误判，把排查方向带偏。同一字段在别处（`已签名 n / 10`）写法是对的，**两处口径不一致时以字段定义为准，并统一**。
- **查「某字段有没有被写入」必须同时搜 `字段:` 与 `字段 = ` 两种形式**。只搜 `provisioningProfileUUID:`（构造器标签）会得出「扩展 UUID 从未落库」的错误结论，而真实写入是 `app.extensions[index].provisioningProfileUUID = binding.profileUUID`。**结论依赖 grep 完备性时，先确认搜索模式覆盖了赋值 / 解构 / 下标三条路径**，否则会基于假前提写错修复方案。
- **设备端 profile 的清理范围要按「本次安装实际装上的那一组」算，不能按主 Bundle ID**。一次安装会为**每个扩展**各装一份 profile（抖音 8 扩展 = 9 份）。只按主 Bundle ID 匹配 ⇒ 扩展的旧 profile 从头到尾没人清理（真机：LiveContainer 的 ShareExtension 一天堆 6 份）。反过来也不能把 `Frameworks/*.framework/embedded.mobileprovision` 算进保留集合 —— 它不会被 installd 装成设备 profile，算进去等于给那个 Bundle ID 发免死金牌。
- **扩展包的容器后缀是 `.appex`，不是 `.app`**。写「找出所有会被安装的 bundle」这类谓词时，只匹配 `.app` 会**静默漏掉全部扩展**——守卫全绿、测试也可能绿（如果测试恰好只断言主 App），但扩展清理根本没生效。本仓统一约定是 `pathExtension == "appex"`（见 `SigningWorkspace`、`AppBundleSigningIdentityReader`、`ApplePortalSigningService`），新代码照此对齐。**这类「绿着坏掉」的缺陷要靠「断言目标物确实被包含」的测试抓**：`SignedArtifactProfileReaderTests` 里 `collectsMainAndExtensionProfiles` 断言 `count == 2` 才把它暴露出来，而只断言「framework 被排除」的那条当时是**假通过**。
- **删错一份设备 profile = 对应 App 立刻无法启动**（iOS 启动时会校验 profile 是否还在设备上）。所以「拿不到可信的『该保留哪一份』」时**必须整组跳过**，绝不能猜「保留最新那份」——宁可留着旧 profile 占地方。同理，以记录为删除依据时要注意**乐观值与已安装值的边界**：`SigningCoordinator.applySigningResult` 在**签名阶段**就写扩展的 UUID（顶层 `provisioningProfileUUID` 反而等安装校验通过才推进，见 R08），所以「签名成功但安装失败」时扩展记录指向一份设备上不存在的 profile，拿它当保留集合会删掉真正在用的那一份。
- **守卫用 `"片段" in 源码` 断言时，同一模式出现多次就会失去约束力**。删除步骤从 1 处变成 2 处后，`check("guard gate.shouldAbort(token) == false else" in job)` 在删掉其中一处的变异下仍然通过（被另一处掩盖）—— 守卫变成「永远全绿」，比直接失败更危险。**同一模式出现多次时改为按出现次数断言**（`job.count(...) >= 2`）。这次是变异测试自己把问题暴露出来的。
- **字段存在不等于语义可信**。`AppExtensionRecord.provisioningProfileUUID` 有值，但它的写入时机（签名阶段）比顶层字段（安装校验后）早，两者**可信度不同**。任何「以记录为删除/撤销/覆盖依据」的逻辑，都要先问「这个字段是在哪个时点写的、那时设备上真的换了吗」。
- **`build-package` 不编译测试 target，所以测试代码的编译错误会绕过它、只在 `swift-regression` 红**。本机无 Swift 工具链时，给 `SealTests/**` 加新调用（尤其是构造器）等于「盲写」，一轮 CI 白等 13 分钟。2026-09-16 实际踩到：`error: argument 'ipaRelativePath' must precede argument 'signedArtifactStatus'`（Swift 的 memberwise init **强制实参顺序与声明一致**，漏写中间的默认参数可以，但顺序不能颠倒）。**对策**：守卫 R09 用 Python 解析 `AppRecord` 声明的参数序列，逐个校验所有调用点的标签顺序；**同类坑当天咬了第二次**（给 `signAndInstall` 加 `onInstallProgress` 时写到了 `broadcastsInstallStage` 之后），现已把 R09 通用化为「声明文件 + 声明锚点 + 调用点正则 + 调用点数下限」的列表，覆盖 `AppRecord` / `signAndInstall` / `installSignedIPA` / `installCachedSignedIPAIfPossible`。加新调用前**逐字段对照声明顺序**，别凭记忆。
- **「进度条停在 X% 不动」要先问「这个阶段到底有没有进度回调」**。iOS 安装阶段（installd 经 installation_proxy 安装）**完全不回报进度**：上传结束（1.01 哨兵）之后到安装完成之间，UI 拿不到任何数值。所以「停在 93%」「卡在传输中」往往不是进度 bug，而是**阶段推进缺失 + 缺少等待说明**。两个界面表现不同只是因为订阅的东西不同：单签订阅 Double 哨兵（能切到 `.installing` ⇒ 93%，然后静止），**批量只订阅 `SigningStage`、根本收不到哨兵**，于是整段停在「传输中」。判据：`SigningProgressView.overallProgress(.installing) == 0.93`、`BatchRefreshView.runningStageTitle(.pushing) == "传输中"`。
- **`guard app.applicationState == .active else { return }` 出现在「自动切后台」流程里是危险的**。`.inactive` 是**瞬时**失焦（控制中心、通知横幅、来电、App 切换器预览、系统弹窗），进程仍在前台。Seal 自续签依赖「旧进程让出前台」才能被 iOS 完成替换，把 `.inactive` 当「用户已离开」直接 return，会连 `exit(0)` 兜底一起跳过 ⇒ 界面永久停在 93%。**只有 `.background` 才算用户真的切走了**；`.inactive` 要等它恢复，恢复不了就走兜底退出。
- **运行中的模态抽屉必须有退出通道**。`showsFooter: !isRunning` 配合 `.interactiveDismissDisabled(isRunning)` = 运行中既没有按钮也不能下滑关闭。真卡住时用户被锁死在一个静止弹窗里，感受就是「怎么都没反应」——这跟进度显示是**两个独立**的体验缺口，修了进度也别把退出通道忘了。运行中至少留一个「取消」（**软取消**：立即关界面，已下发的安装由 installd 跑完，结果以列表刷新为准）。
- **守卫里「扫到 0 个调用点」= 检查必然通过**。新写的实参顺序校验第一版正则用了 `(?<![A-Za-z0-9_.])signAndInstall\(`，而真实调用点全是 `coordinator.signAndInstall(`（前一个字符是 `.`），被反向断言全部排除 ⇒ 零调用点 ⇒ 零错误 ⇒ 绿。**凡是「遍历 + 断言」的守卫都必须一并断言「扫到了多少个」，并设下限**，否则改一个正则就能让它静默失效。
- **变异检查的期望文案必须与真实断言文案对得上**。`any(item.startswith(expected))` 是按前缀匹配的：文案写错会报成 `Guard failed mutation check`，看起来像「变异没被抓到」，实际是断言已被触发但消息不匹配。看到这条失败先核对真实消息，再改锚点。
- **守卫脚本自己也会慢到被超时杀掉**。`violations()` 在变异检查里要跑 70+ 遍，每遍都 `rglob` 目录 + `strip_comments` 全部 Swift 源码（约 2MB 的纯 Python 字符循环）⇒ 近 3 分钟，超过默认命令超时被 SIGTERM（表现为「无任何输出、exit 1」，很容易误判成脚本崩了）。**每遍内的 `load` 与 `strip_comments` 结果都要缓存**（缓存必须限定在单遍作用域内 —— 跨遍缓存会读到陈旧文本，让变异检查静默失效；另外重绑 `load = load_cached` 前要先把原始 loader 存到另一个名字，否则闭包递归到自己）。`rglob` 结果在进程内只算一次。优化后 48 秒。
- **两条链路各抄一份同一条规则 = 迟早漂移，而且漂移不会编译失败**。安装阶段的计时起点规则（进入 `.installing` 记一次、重复推送不重置、离开清空）原先在 `AppsViewModel.updateSigningStage` 与 `BatchRefreshSession.advanceStage` 各有一份拷贝。漂移后单签与批量的「已等待 m:ss」必有一个变成假象（永远 0:00，或带上上一项的等待时间），**没有任何编译 / 测试信号**。对策是抽成纯函数（`InstallStageTimeline`）两边共用，并让守卫断言「两处都调它」。
- **源码文本断言守「形状」，单测守「行为」，两者不能互相替代**。`.inactive → .waitForForeground` 这条分支是「Seal 自续签永久停在 93%」的根因，修完当时**只有守卫里的字符串断言** —— 重构可以把它改成任何返回值，只要那行文字还在，守卫就绿。**凡是「错了不崩、只在真机上卡死」的分支，必须先把判断抽成可测的纯函数（如 `SelfInstallAutoBackground.step(for:)`）再写单测**；守卫那边同时断言「单测文件里的关键断言确实存在」，防止测试被删空后仍然全绿。
- **副作用触发点不要挂在界面上 —— 界面会消失，副作用不该跟着消失**。Seal 自续签的「回主页」原先挂在 `SigningProgressView.onChange`。同一个版本里我给运行中的抽屉加了「取消」按钮（软取消：立即关界面，**已下发的安装由 installd 跑完**），于是用户在安装阶段点取消 ⇒ 界面消失 ⇒ 挂在界面上的触发点收不到后续阶段推进 ⇒ 替换静默失败。**判据：这个副作用是「状态到达某一点就该发生」，还是「用户看着界面时才该发生」**；前者必须放在状态层（ViewModel / Coordinator），界面只负责渲染。同类隐患还有：挂在界面上的埋点、上报、清理任务。**加了「关闭/取消」通道之后，要复查一遍有哪些副作用是挂在被关闭的那个界面上的。**
- **重复推送的阶段推进要设「首次进入」闸门**。`updateSigningStage(.installing)` 会被调用不止一次（安装通道的 >1.0 哨兵 + 签名侧补发），挂在它上面的副作用（起计时、触发「回主页」）必须用 `InstallStageTimeline.Tick == .restart` 之类的闸门只跑一次，否则会排出多个任务。
- **同步阻塞 FFI 的等待必须带超时，否则「卡住」= 永久**。`Minimuxer.stageAndInstall` 没有取消机制，自替换分支原先写的是裸的 `try await installation.value` —— 一旦底下不返回，界面就永久停在 93%，进程还活着（其它后台任务照常打日志），**从外面完全看不出区别**。普通 App 分支有 `offThread(seconds:)` 兜底，所以这个缺陷只出现在 Seal 自续签上。**判据：凡是 `await` 一个「无法取消的同步调用」，都要问「它不返回会怎样」**；答案若是「永久」，就必须加看门狗。
- **「停止等待」和「取消工作」是两件事，别用同一个开关**。`offThread` 走 `HardTimeout.run` 的默认 `cancelsWorkOnTimeout: true`，超时会把承载 FFI 的任务 `cancel()`。同步 FFI 本身响应不了取消，但 **Rust 侧若把取消信号当「调用方放弃」来清理，就会撤销已经下发的 installation_proxy 命令** —— 那是把「可能还在装」变成「确定装不上」。自替换只能**停止等待**（显式 `cancelsWorkOnTimeout: false`），绝不能取消。
- **会「静默卡死」的链路必须自带日志**。安装（尤其自替换）在 2026-09-16 之前一行日志都没有：真机日志里 Seal 自替换在「签名产物核验通过」之后 93 秒空白、没有任何结论，而**同一天的普通 App 安装从开始到「签名并安装成功」只有 7 秒**。没有「安装调用已返回」这类对照日志，「卡住」和「在装」在日志上无法区分。安装阶段 installd 不回报任何进度，所以还要有**心跳**（每 15 秒一条）。日志必须 `flush()`：自替换的终点是当前进程被替换掉，留在缓冲里的最后几行会随进程消失。
- **同一个 Bundle ID 上不能有两个并发 installd 命令（R05）**。真机日志 Seal-log(8) 里 91 秒内提交了两笔自替换安装，而第一笔从未返回 —— 用户「怎么都没反应」之后重试，就在同一 Bundle ID 上叠了第二个安装命令。同步 FFI 取消不掉，所以只能**在入口用闸门拒绝第二笔**；而且**超时不解锁**（底下那次很可能还在跑），并且这类拒绝要按终态处理 —— 重试路径里的 `Minimuxer.reset()` / `Install.resetProvider()` 会把可能仍在跑的安装连接拆掉，比不重试更糟。
- **把重复实现合并成一份时，记得同步更新按「出现次数」断言的守卫**。安装通道的无进度重载改为转发到带进度的实现后，`count("if Self.isTimeoutInstallError(error) {") == 2` 这条断言立刻失效（变成 1）。这是**预期内的失败**，改断言而不是把实现写回去。同理，给某个常量/片段加断言前先确认它在文件里出现几次 —— `logStore: logStore` 在 `AppContainer` 里同时出现在安装通道与签名协调器两处，全局匹配会让「只改安装通道那一处」的变异检不出来（本轮实际踩到，改用 `section()` 限定构造段）。

---

## 历史记录

### 2026-09-16（续 4）· 用真机日志坐实「卡在 93%」：自替换安装调用从未返回，而这段一行日志都没有

- **现象（用户问题 1）**：续签到安装步骤卡在 93%，「怎么都没反应」。上一轮已经修了三个缺陷（批量收不到 `.installing`、安装期无反馈、`.inactive` 早退），但用户复测仍然卡住。
- **决定性证据（来自用户导出的 `Seal-log(7).txt`，同一份日志内的对照）**：
  - `16:59:06` 开始安装 LiveContainer（4 个 target）→ `16:59:13`「签名并安装成功」= **7 秒**；
  - `16:53:57`「签名产物核验通过」是 **Seal 自替换**的安装起点 → 之后 **93 秒完全空白** → `16:55:30` 才出现下一条日志，而且是无关的后台任务（`[BatchDebug] restore skipped`），**没有任何安装结论**；
  - 之后进程一直活着并继续打后台日志（`16:55`–`17:02`），说明 Seal **从未被替换**，也从未写出「签名并安装成功」。
  - `Seal-log(8).txt`：`19:43:50` 与 `19:45:51` 各有一次 Seal 自替换安装起点，间隔 91 秒，两次都没有结论 —— 第二次是用户在「没反应」之后重试。
- **根因**：`MinimuxerInstallChannel.install(...)` 的自替换分支是裸的 `try await installation.value`，**没有超时、没有任何日志**。`Minimuxer.stageAndInstall` 是同步阻塞 FFI、无取消机制，所以它不返回 = 界面永久停在 93%、日志永久静默、用户无从判断「在装」还是「死了」。普通 App 分支有 `offThread(seconds: mergedTimeout)` 兜底，这就是为什么只有 Seal 自续签会永久卡住。
- **修复**：
  1. **看门狗**：自替换等待改用 `HardTimeout.run(seconds:budget, cancelsWorkOnTimeout: false)` —— 超时**只停止等待、绝不取消**底层 FFI（`offThread` 的默认 `true` 会把取消传给 Rust 侧、可能撤销已下发的 installation_proxy 命令）。超时后**不重试**（R05），并按终态**原样抛出** `installTimeoutFailure`，不再经 `installationFailure` 归类改写文案。
  2. **日志出口**：`MinimuxerInstallChannel` 注入可选 `SealLogStore`（`AppContainer` 里把 logStore 的构造提前到安装通道之前），每次安装写「开始 / 已返回 / 抛错 / 等待超时」，自替换等待期间每 15 秒一条心跳。每条日志立刻 `flush()` —— 自替换的终点是进程被替换，缓冲里的最后几行会随进程消失。
  3. **单飞闸门**：新增纯类型 `SelfReplacementInstallGate`，同一时刻只允许一笔自替换安装；**超时不解锁**（底下那次很可能还在跑），非超时错误才解锁。两条重试路径都把「被闸门拒绝」按终态处理（重试路径里的 `reset()` 会拆掉可能仍在跑的安装连接）。
  4. **消掉重复实现**：无进度的 `install(ipaData:bundleID:isSelfReplacement:)` 改为转发到带进度的实现（进度回调传空实现），不再各维护一份「自替换必须带看门狗 / 必须记日志 / 必须单飞」的规则。
  5. `diagnostic(_:)` 移到 `#if !targetEnvironment(simulator)` 之外：看门狗要在模拟器上也能编译（它不碰 Minimuxer 的安装 API，但抛错日志要用这段文本）。
- **测试**：新增 `SelfReplacementInstallGateTests`(4)（第二笔必须被拒、安装结束后解锁、**超时不解锁**、连续超时永不重开）；`HardTimeoutTests` 补 1 条行为测试 —— 用锁保护的探针断言 `cancelsWorkOnTimeout: false` 时**工作所在任务**的 `Task.isCancelled` 仍为 false（闭包里不能再套一层 `Task.detached`，否则测的是新任务，测试会退化成永远通过）。
- **结果**：守卫 **203 源码 + 89 变异 PASS**（上一轮 189 + 82）。旧的 `count("if Self.isTimeoutInstallError(error) {") == 2` 因重载合并降为 1，已同步改为「唯一的重试循环必须把超时当终态」。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Application/AppContainer.swift`、`SealTests/Installation/SelfReplacementInstallGateTests.swift`(新)、`SealTests/Concurrency/HardTimeoutTests.swift`、`Scripts/verify-release-safety.py`、`docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md`。
- **验证状态**：守卫本地 PASS；Swift 编译与单测待 `swift-regression`；真机回归仍待用户执行（本轮新增「安装阶段日志应出现开始/返回/心跳」这条可验证项）。
- **仍未定论**：自替换**为什么**不返回，目前只有日志证据（调用不返回），没有设备侧证据。修复让「永久卡住」变成「有界失败 + 可查日志」，下一轮真机日志应能直接读出是上传卡住、installd 卡住，还是 `SelfInstallAutoBackground` 的 `suspend` 冻结了承载 installation_proxy 的连接（后者与通道里「提前 suspend 会冻结连接」的注释直接冲突，是首要嫌疑）。

### 2026-09-16（续 3）· 修掉「加了取消按钮之后」自己引入的缺陷：回主页触发点被界面带走

- **现象（自审发现，非用户反馈）**：Seal 自续签的「回主页」动作挂在 `SigningProgressView.onChange` 上，而同一版本新加的「取消」按钮是**软取消**（立即关界面，已下发的安装由 installd 跑完）。用户在安装阶段点取消 ⇒ 界面消失 ⇒ 触发点收不到后续阶段推进 ⇒ **「回主页」永远不会发生**，iOS 等不到旧进程让出前台，Seal 的替换静默失败（旧版本继续跑，用户以为更新没生效）。
- **根因**：副作用触发点挂在界面上。批量续签那条链路本来就在状态层触发（`consumeBatchEvent`），单签没有对齐。
- **修复**：触发点搬到 `AppsViewModel.updateSigningStage`，并用 `InstallStageTimeline.Tick == .restart` 闸门保证**只在首次进入安装阶段触发一次**（同一阶段会被重复推送）；界面上的 `.onChange` 只保留视觉转场（`withAnimation` 渲染「正在退回主屏幕」）。守卫新增 3 条断言 + 2 条变异：状态层必须有触发且带闸门、界面里**不得**再出现调用（两处都触发 = 两个转场 + 两个 `exit(0)` 兜底）。
- **顺带记一笔**：批量链路的 `if stage == .installing` 没有 `.restart` 闸门，重复推送时会排出多个「回主页」任务 —— 已知且**良性**（第一个任务触发转场后进程被挂起，后续任务不会执行；转场失败时第一个 `exit(0)` 已结束进程），本轮刻意未动，已记入 QA 文档的「未解决」表。
- **结果**：守卫 **189 源码 + 82 变异 PASS**（上一轮 186 + 80）。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`Scripts/verify-release-safety.py`、`docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md`、`DEBUG_LOG.md`。
- **验证状态**：守卫本地 PASS；Swift 单测与真机回归待 CI / 设备侧。

### 2026-09-16（续 2）· 把两条「只在真机上卡死」的分支补上单测，并消掉一份重复规则

- **背景**：上一轮修掉的 `.inactive` 早退（Seal 自续签永久停在 93%）与安装计时起点规则，当时只有守卫里的源码文本断言，**没有单测覆盖**。这两处都属于「错了不崩、只会在真机上卡死」的类型，恰恰最需要测试钉住。
- **改动**：
  1. `SelfInstallAutoBackground` 抽出 `enum ReturnHomeStep { .standDown / .triggerTransition / .waitForForeground }` 与纯函数 `step(for state: UIApplication.State)`，等待循环 `waitUntilExitIsSafe` 改为走它（`.inactive` 等最多 3 秒，仍不恢复才走 `exit(0)` 兜底）。新增 `SelfInstallAutoBackgroundTests`(5)：`.inactive` 必须 `.waitForForeground`、只有 `.background` 才允许 `.standDown`、未知状态按「还在前台」处理、穷举「全部已知状态里恰好一个走 `.standDown`」。
  2. 安装计时起点规则抽成 `InstallStageTimeline.tick(entering:currentStage:)` → `.keep / .clear / .restart`，`AppsViewModel.updateSigningStage` 与 `BatchRefreshSession.advanceStage` 共用；`updateInstallProgress` 的哨兵分支不再自己写 `status` / `installStartedAt`，改为复用 `updateSigningStage(.installing)`。新增 `InstallStageTimelineTests`(5)。
  3. 守卫 R10 从文本匹配升级为结构断言：新增 `squash()` 辅助函数（多行代码压成一行式断言，不再拼换行符 + 数缩进空格）；断言等待循环**真的走** `step()` 且真的 `sleep`、`@unknown default` 不放弃、两个新单测文件里的关键断言确实存在。旧的一条变异锚点锚定的是被删掉的旧写法，已替换为 6 条新锚点。
- **结果**：守卫 **186 源码 + 80 变异 PASS**（上一轮 176 + 75）。
- **涉及文件**：`Seal/Core/Signing/InstallStageTimeline.swift`(新)、`Seal/Core/Renewal/BatchRefreshSession.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、`SealTests/Apps/SelfInstallAutoBackgroundTests.swift`(新)、`SealTests/Signing/InstallStageTimelineTests.swift`(新)、`Scripts/verify-release-safety.py`。
- **验证状态**：守卫本地 PASS；Swift 单测待 `swift-regression`；真机四项回归（见 `docs/qa/2026-09-16-install-stage-feedback-and-self-replacement-freeze.md`）仍待用户执行。

### 2026-09-16（续）· 续签「卡在 93%」与「卡在传输」：安装阶段的反馈缺失 + 自替换的永久冻结

- **现象（用户问题 1、2）**：①续签到安装步骤卡在 93%，「怎么都没反应」；②续签抽屉卡在「传输」那，一直没反应。
- **根因（三个独立缺陷，恰好同时命中「安装阶段」）**：
  1. **批量续签收不到「安装中」阶段**。`installSignedIPA` 的普通 App 分支只发 `.pushing`；上传完成后的 1.01 哨兵（Double）只有单签路径的 UI 订阅得到，而 `BatchRefreshEvent` 只承载 `SigningStage` ⇒ **普通 App 在批量里从上传完成到 installd 装完整段显示「传输中」**（可达数分钟）。这是问题 2 的直接根因。原 `broadcastInstallingForSelfReplacement` 标志只作用于 Seal 分支，名字也误导（它实际表达的是「调用方的进度回调看不到 Double 哨兵」）。
  2. **安装阶段完全没有可见反馈**。installd 安装期间没有任何进度回报，单签只能给出一个静止的 93%，批量连百分比都没有（「传输中」是个没有分母的黑盒）。
  3. **Seal 自续签的「回主页」可能永久不触发**。`SelfInstallAutoBackground.returnToHomeAfterSealUpload` 里 `guard app.applicationState == .active else { return }` 把**瞬时失焦** `.inactive`（控制中心/通知横幅/来电/系统弹窗）当成「用户已离开」，直接 return —— **连 `exit(0)` 兜底一起跳过**。而 iOS 只有在旧进程让出前台后才完成替换 ⇒ 界面永久停在 93%。这是问题 1 最可能的根因。
- **修复**：
  1. `InstallStageBridge.shouldEmitInstalling(uploadProgress:enabled:)` 抽出「上传完成哨兵 → 补发 `.installing`」的规则（`> 1.0` 而非 `>=`，1.0 只是「上传到 100%」）；`SigningCoordinator.bridgedInstallProgress` 让 **Seal 自替换与普通安装两个分支共用同一份包装**，标志改名为 `broadcastsInstallStage`（语义：调用方的进度回调是否只承载 `SigningStage`）。批量续签传 `true`。
  2. 批量事件流新增 `BatchRefreshEvent.appInstallProgress(index:total:app:progress:)`，把安装通道 AFC 的真实上传百分比送进抽屉；`BatchRefreshSession.recordInstallProgress` / `advanceStage` 管好「只在 `.pushing` 采信」与「进入 `.installing` 记一次起点」。
  3. 新增 `InstallWaitNote`（`TimelineView` 秒级计时）：安装阶段明说「此阶段没有进度回报」并给出「已等待 m:ss」，单签进度页与批量抽屉共用。**刻意不编造假百分比** —— 安装耗时与包大小/设备 IO 相关，任何线性假设都会在慢设备上「走完却还没装完」。
  4. 两个抽屉的 footer 改为**常显**并各加一个取消按钮（`cancelSigning` / `cancelBatchRefresh`，软取消 + 日志 `SEAL-SIGN-012` / `SEAL-RENEW-011`），解决「被关在静止弹窗里、没有任何操作」。
  5. `SelfInstallAutoBackground`：只有 `.background` 才算用户离开；`.inactive` 先等最多 3 秒等它恢复，恢复不了照样走 `exit(0)` 兜底，保证 iOS 一定能完成替换。
- **守卫与测试**：新增 **R10**（安装阶段「看得见、退得出」共 11 条断言 + 6 个变异锚点）；**R09 通用化**为可复用的实参顺序校验（覆盖 4 个函数，含「调用点数下限」防绿着坏掉）；修掉守卫自身的性能问题（每遍缓存 `load`/`strip_comments`、`rglob` 只算一次：2m47s → 48s）。新增测试 `InstallStageBridgeTests`(2) / `BatchRefreshSessionTelemetryTests`(5) / `InstallWaitNoteTests`(2)。结果 **176 源码 + 75 变异 PASS**。
- **涉及文件**：`Seal/Core/Signing/InstallStageBridge.swift`(新)、`SigningCoordinator.swift`、`SigningSession.swift`、`Seal/Core/Renewal/{RenewalCoordinator,BatchRefreshSession}.swift`、`Seal/DesignSystem/InstallWaitNote.swift`(新)、`Seal/Features/Apps/{AppsViewModel,BatchRefreshView,SigningProgressView}.swift`、`SealTests/{Signing/InstallStageBridgeTests,Renewal/BatchRefreshSessionTelemetryTests,DesignSystem/InstallWaitNoteTests}.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：静态守卫 PASS。**待 macOS 编译 + 真机回归**：批量续签时抽屉应显示上传百分比、上传完成即切「安装中」并出现「已等待 m:ss」；单签进入安装阶段应出现同样的等待说明；运行中点「取消」能立即退出界面；Seal 自续签在失焦（下拉控制中心）后仍能完成替换而不是停在 93%。
- **仍未闭环**：安装/上传超时预算偏长（`mergedTimeout = min(1800, 180+ipaMB×5) + 600`，20MB 包 ≈ 878 秒）——是否缩短需要用户拍板，缩短的代价是慢设备上的假超时（超时按确定性拒绝处理、不重试，但底层安装可能仍在跑，会留下「装上了却记为失败」）。另需用户补完问题 6。

### 2026-09-16 · 设备端描述文件只增不减（Seal 自己 17 份）+ 序列号/UUID 版式统一

- **现象（用户报 6 条，第 6 条被截断）**：①续签到安装卡在 93% 无反应；②续签抽屉卡在「传输」无反应；③证书序列号要左右一行、超长中间省略；④描述文件 UUID 同样左右一行；⑤描述文件每次申请旧新并存，Seal 已有 16 个 UUID 对应的文件；⑥「签名、续签」（未写完）。
- **证据来源**：用户随后发的两张截图是 **StikDebug** 的「App Expiry」页（不是 Seal 界面 —— Seal 只有 Apps / Settings 两个 Tab，截图里是三个；`App Expiry`/`Other Profiles` 等字符串在 Seal 代码里搜不到）。但它经 misagent 读的是设备真实 profile 库，数据可信：
  - `com.mjorb.seal.CT8QZ7352B` → **17 份**（1 最新 + 16 旧，界面写「Show 16 older profiles」）
  - `com.kdt.livecontainer.seal.3432ZHJUF9` → 3 份
  - `com.kdt.livecontainer.seal666.ShareExtension` → ≥6 份，到期日全在 `2026-09-17`（有效期 7 天 ⇒ **创建于同一天 09-10，一天内重签 6 次以上**）
- **根因（两条独立泄漏路径，清理代码本来就存在，但触发条件与匹配范围都有缺口）**：
  1. **只按主 Bundle ID 匹配**：`SignedArtifactProfileReader` 只认恰好三段的 `Payload/<App>.app/embedded.mobileprovision`，而一次安装会为**每个扩展**各装一份 profile ⇒ 扩展的 profile 从来没被清理过。
  2. **只在安装成功那一刻触发**：`AppMaintenanceJob`（空闲维护）三步里**完全没有**描述文件清理 ⇒ 历史堆积永远回收不了；Seal 自己的自更新走 `SelfReplacementCoordinator` 事务链而非 `installSignedIPA`，清理条件更严、更容易整批跳过。
- **修复**：
  1. `SignedArtifactProfileReader.embeddedProfiles`：枚举**全部**会被安装的位置（主 App + PlugIns/AppClips/Watch），**排除 `Frameworks/*.framework`**；Bundle ID 取自 profile 自身的 `application-identifier`（剥 TeamIdentifier 前缀），不从路径推断。
  2. `DeviceProfileCleaner` 改为「Bundle ID → 保留 UUID」映射：**key 集合之外的一律不碰**（设备上还有 MDM / 企业证书 / 其它工具装的 App）。
  3. `SigningCoordinator` 安装后按整组 profile 清理，扩展不再漏。
  4. `AppMaintenanceJob` 新增**第 4 步**设备端描述文件清理 —— 这一步是清掉历史堆积的关键，它不依赖某一次安装成功。
  5. 两条安全红线：**拿不到可信 UUID 就整条跳过**（宁可留着，删错会让 App 立刻无法启动）；**扩展记录仅在 `signedArtifactStatus == .installed` 时采信**（`applySigningResult` 在签名阶段就写扩展 UUID，安装失败时它是乐观值）。Seal 自己则以运行时读到的真实 profile 覆盖记录值。
  6. 版式统一（问题 3/4）：`AppDetailView.serialDetailRow`/`profileDetailRow`、`InstalledAppActionSheet.metadataValueRow`、`AppSigningSheet.summarySerialRow`、`SigningProgressView.runtimeSerialRow` 五处改为 HStack 左右一行 + `.truncationMode(.middle)` + `.textSelection(.enabled)`。
- **守卫与测试**：`Scripts/verify-release-safety.py` 新增 **R08**（5 条断言）+ **4 个变异锚点**；顺带修掉一处**被自己削弱**的既有断言（`C: the sweep must re-check the lease` 原本用 `in`，删除步骤变 2 处后被掩盖 ⇒ 改为按次数断言 `>= 2`）。新增 `AppMaintenanceJobTests` 4 条 + `SignedArtifactProfileReaderTests` 4 条。结果 **147 源码 + 64 变异 PASS**。
- **涉及文件**：`Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift`、`DeviceProfileCleaner.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Core/Maintenance/AppMaintenanceJob.swift`、`Seal/Application/AppContainer.swift`、`Seal/Features/Apps/{AppsViewModel,AppDetailView,AppSigningSheet,InstalledAppActionSheet,SigningProgressView}.swift`、`SealTests/Import/Fixtures/IPAArchiveFixture.swift`、`SealTests/{Maintenance/AppMaintenanceJobTests,Signing/SignedArtifactProfileReaderTests}.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：静态守卫 PASS。**待 macOS 编译 + 真机回归**：打开 Seal 静置触发空闲维护后，StikDebug 的 App Expiry 页里 Seal 应从 17 份降到 1 份，日志出现 `设备端旧描述文件清理：扫描 N，匹配 M，删除 K`（`SEAL-PROFILE-320`）；若出现 `stage=dump` 或 `skipped-record-read-failed` 说明隧道/misagent 通道没起来。
- **仍未解决**：问题 1（93% = `.installing`，`installTimeout=600s`、`pushTimeout≈180+ipaMB×5`，可能长停 4.6–10 分钟）与问题 2（「传输」= `.pushing`；抽屉里 Seal 那项应显示「即将更新」，卡在「传输中」的大概率不是 Seal）**都需要卡住那一刻前后 1 分钟的 Seal 日志**；问题 6 待用户补完。
- **详见**：`docs/qa/2026-09-16-profile-pileup-and-ui-row-layout.md`。

### 2026-09-16 · 抖音（8 扩展）签名必失败：Apple 限流被误报成「登录过期」；批量续签解阻塞

- **现象**：签抖音（主 App + 8 扩展 = 9 个 bundle ID）时，**无论怎样都会在「正在验证 Apple ID」报错失效**，反复重新验证 Apple ID 也无效；签其他 App（Kazumi 1 个 bundle ID、Sollin Player 2 个）完全正常。用户认为「id 名额足够」。
- **根因**：`ApplePortalSigningService.prepareProfile` 对 9 个 bundle ID 串行执行 Phase 1（`addAppID` + `updateFeatures` ×9）与 Phase 2（描述文件申请 ×9，每次含 delete + 重取），**短时间二十余次密集请求触发 Apple 对免费账号的限流**，返回 `1100 Your session has expired`。
  - **决定性证据**：每次 `AUTH-107` 报错前 1–3 秒都有一条「证书决策」成功日志（21:15:40→21:15:41、21:18:14→21:18:16、21:31:43→21:31:46）。证书能申请成功说明 session 在服务端仍然有效。
  - **旁证**：同一账号 `mar***7***@gmail.com` 在 21:07:38 刚成功签完 Kazumi，6 分钟后签抖音即报「登录过期」。
  - 代码里原本已有注释提到「1100 在 App ID 创建阶段也会出现（如抖音签名时）」，但只做了错误分类，没有处理限流本身 —— 分类正确了，问题还在，用户被反复引导去重新验证。
- **修复**：
  1. 新增全局 `AppleRequestThrottle`（相邻请求 ≥ 0.4 秒），挂在 **`withAppleTimeout` 开头** —— 它是所有 Apple 请求的唯一入口，一处覆盖全部调用点。节流只在间隔不足时等待，对 500ms 轮询与单 App 签名零影响。
  2. 新增 `withSessionRecovery`：对 `addAppID` / `fetchProvisioningProfile` 命中 1100 时退避重试（1.5s / 4s / 8s），耗尽才抛。**只重试 1100**，网络超时、Bundle ID 冲突（9400）、名额上限（3013）仍立即失败。
  3. **App ID 阶段的 1100 文案与 account 阶段拆开**：前者改为「Apple 暂时拒绝了请求 / 请先等几分钟再重试」，后者保留「去重新验证」。这是打断死循环的关键。
  4. 消除 `diagnostic.contains("1100")` 子串误判，统一走 `isSessionExpiredError`（只认错误码 + 官方文案）。
- **附带修掉**：`SettingsViewModel` 把 `usedBundleIDCount`（已注册存活数）渲染成「N 个可用 App ID」，语义完全反了 —— 日志里「10 个可用」实为**已用满 10 个**，直接造成用户「名额足够」的误判。改为「已注册 N / 10」，与 `CertificatesRootView` 的「已签名 n / 10」统一。
- **同轮做的优化**：`startBatchRefresh` 去掉前置 `await refreshSigningChannel()`（「点续签后卡很久」的第二个入口）。解阻塞的前提是**先在通道层加失败熔断**（60 秒窗口）—— 否则通道不可用会退化成 N×75s 诊断。熔断配合既有 `inFlightStart` 单飞，整轮批量只付一次诊断代价。用户发起的会话显式 `clearFailureCooldown()`，不会被熔断误挡。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`Seal/Core/Installation/InstallChannel.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/Signing/AppleRequestThrottleTests.swift`（新增）、`Scripts/verify-release-safety.py`。
- **待核对的结构性约束**：免费账号 App ID 名额是「7 天窗口内最多 10 个」，**一轮抖音签名就吃掉 9 个**（主 + 8 扩展），7 天后过期又要重注册。这是 Apple 侧限制，代码无解 —— 建议抖音用付费账号签，或接受丢弃部分扩展。本次失败全部是 `AUTH-107`，没有一次 `SEAL-APPID-304`，所以名额不是本次的直接原因，但值得用户核对。
- **验证状态**：静态守卫 PASS（139 源码断言 + 59 变异）。**待 macOS 编译 + 真机回归**（本机无 Swift 工具链）。真机重点：日志里是否出现「Apple 会话疑似被限流，退避 N 秒后重试…」；退避后是否成功；批量续签是否不再长停「正在连接设备」。

### 2026-09-16 · 自续签 7 问：连设备卡顿（真 bug）、证书/描述文件展示统一、关联判定同源、回主屏转场

- **现象（用户报的 7 条）**：
  1. 签名/续签卡在「正在连接设备」很久。
  2. 「Apple ID 证书 · 序列号 xxx」要统一成「证书序列号 + 完整序列号」，且序列号要显示全面。
  3. Seal 自续签的蓝色文案要跟普通 App 一样。
  4. 续签后的证书没关联到 Seal 自己（「此证书已安装 App」里看不到 Seal）。
  5. 要确认用的是真实的 7 天新时间，而不是假数据（怕第二天掉签）。
  6. 续签完回主屏像闪退，要有过渡。
  7. 描述文件「可用」要换成「该应用使用的 UUID」独占一行灰色。
- **根因**：
  1. **真 bug**：`SigningCoordinator` 里「隧道与签名并行」已做过，但 `AppsViewModel.runSigning` 在调用协调器**之前** `await refreshSigningChannel()` → `installChannel.start()`，把整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询，硬超时 75s）又同步等了一遍，并行化对首个调用完全失效；`updateState/.progress(.waitingForChannel)` 又把 UI 钉在「正在连接设备」。
  2. 序列号在标题右侧单行渲染 + `.truncationMode(.middle)` + `.minimumScaleFactor(0.8)`，40 位十六进制必然被截断；「序列号 · 」前缀还白占位置。
  3. Seal 专属 `sealReplacementTip`（「请按 Home 键回到主屏幕」）是「自动回主屏」上线前的产物，现在说反了。
  4. **真 bug**：同一张证书的两处展示不同源 —— 行标签用 `associatedApps`（含扩展 target），下方清单用 `affectedApps`（只看顶层 serial + `state == .installed`），于是「标签说在用、清单说暂无」；Seal 的 `belongsInInstalledList` 恒为真但 `state` 不一定是 `.installed`，被前置条件挡掉。
  5. 代码侧已三重强校验真实 7 天（取到即校验 + 不达标同会话重取 + 成品包 embedded profile 再验），但 UI 不暴露 profile 身份，用户无法自证。
  6. `SelfInstallAutoBackground` 静止 2s 后只走一条 `perform("suspend")`，`responds(to:)` 为假时**静默什么都不做**，最后由 installd 杀进程 → 观感等同闪退。
  7. `描述文件` 行显示的是状态枚举文案（`.available` → 「可用」），只回答「有没有问题」，不回答「是哪一份 profile」。
- **修复**：
  1. 新增非阻塞 `AppsViewModel.beginSigningChannel()`（`runSigning` 改用它，不再 await）；`MinimuxerInstallChannel.start()` 增加单飞合并 `inFlightStart`，避免 ViewModel 与协调器并发重跑诊断；`SigningCoordinator` 安装前 await 通道时不再 `try?` 吞错，只在 `isReady()` 为假时抛底层 `SEAL-VPN-*`/`SEAL-PAIR-*`。
  2. `certificateName(serial:)` → `certificateSerialText(serial:)`（只返回完整序列号，去掉前缀）；行标题统一「证书序列号」；值独占一行、灰色等宽、可长按选中。四个入口（详情页 / 进度页 / 操作面板 / 签名表单）全部统一。
  3. 进行中一律 `keepSealOpenTip`；删除 `sealReplacementTip`，新增 `sealReturningHomeTip` 只在 Seal 进入 `.installing` 后显示。
  4. 新增 `CertificateRevocationImpact.installedAppsAssociated`（= `associatedApps` + `belongsInInstalledList`），证书页清单改用它；**`affectedApps` 语义未动**，撤销影响评估仍走它；守卫新增断言这条分界 + 4 条单测。
  5. 详情页新增 `描述文件` UUID 行与 `描述文件创建时间` 行：续签后 UUID 变、创建时间是刚刚、有效期 = +7 天，即可自证真实生效。
  6. `SigningProgressView` 新增 `isReturningHome`，进入 `.installing` 先 `withAnimation` 渲染「正在退回主屏幕」再触发系统转场；`SelfInstallAutoBackground.returnToHomeAfterSealUpload()` 双路径 suspend（`perform` → `UIControl().sendAction(_:to:for:)`）+ `exit(0)` 兜底；可感知停顿 2s → 1.2s。
  7. `描述文件` 行的值改为 profile UUID 独占一行灰色等宽可选中；仅当状态不是 `.available` 时保留状态标签（`.mismatch` 是安全信号，不能删）。
- **涉及文件**：`AppPresentation.swift`、`SigningProgressView.swift`、`AppDetailView.swift`、`AppSigningSheet.swift`、`InstalledAppActionSheet.swift`、`AppsViewModel.swift`、`CertificateRevocationImpact.swift`、`SigningCertificateSettingsView.swift`、`MinimuxerInstallChannel.swift`、`SigningCoordinator.swift`、`SealTests/Settings/CertificateRevocationImpactTests.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：`python Scripts/verify-release-safety.py` PASS（Source 129 / Mutation 55）。**待 macOS 编译 + 真机回归**，重点：①单签/续签不再长时间停在「正在连接设备」，且通道真失败时给可操作文案；②Seal 自续签进度→文案切「正在退回主屏幕」→平滑回主屏→重开是最新且设置页自动确认；③证书页 Seal 出现在「本机已安装 App」清单且序列号与详情页逐字符一致；④详情页 profile UUID 与创建时间在续签后都变、有效期 = +7 天。**风险点**：`exit(0)` 仅在 suspend 完全不可用时触发，需确认不会留下旧 profile（若出现，改为「等安装 RPC 返回再退后台」）；1.2s 停顿若导致暂存未落盘被切走，回调到 1.5–2s。
- **详见**：`docs/qa/2026-09-16-renewal-ux-and-cert-issues.md`（含逐条「要求本身合不合理 / 有没有更好的做法」评估）。

### 2026-09-16 · 批量续签 Seal 自动回主页：补发 .installing 信号（含去冗余开关）；签名进度页序列号与详情页同步

- **现象**：
  1. 批量续签里 Seal 到安装阶段不会像单签那样自动回主页。
  2. `SigningProgressView` 的「Apple ID 证书」行只显示「可用」，看不到具体序列号，与应用详情页展示不一致。
- **根因**：
  1. 批量续签的 `progress` 回调（`RenewalCoordinator` → `.appProgress(…, stage:)`）只透传 `SigningStage`，接不到单签用的 1.01 上传哨兵；而 Seal 走 `submitPrepared` 只发 `.pushing`，不发 `.installing` → 批量里 Seal 永无 `.installing`，`consumeBatchEvent` 里 `app.isSeal && stage == .installing` 分支永远不命中。
  2. 两处证书展示各写各的：详情页 `AppDetailView.certificateName` 输出「序列号 · .fullSerial」，签名进度页 `SigningProgressView.certificateDisplayName` 只回「可用」。
- **修复**：
  1. `installSignedIPA` 的 Seal 分支在 `submitPrepared` 上传完成（>1.0）时补发一次 `progress(.installing)`（`SigningCoordinator.swift:1233`），批量经 `.appProgress` 命中 `consumeBatchEvent` 触发 `SelfInstallAutoBackground`。**去冗余**：新增显式开关 `broadcastInstallingForSelfReplacement`（默认 false），仅 `RenewalCoordinator.swift:232` 批量续签传 true；单签续签 Seal 仍靠 `onInstallProgress` 的 1.01 → `SigningProgressView.onChange` 触发，不在此补发，消除对同一事件的双重触发。
  2. `SigningProgressView.certificateDisplayName` 改为复用 `AppSigningPresentationHelpers.certificateName(serial:)`，用 `session.selectedCertificateSerialNumber ?? session.account.certificateSerialNumber` 生成「序列号 · .fullSerial」，与详情页同源同 helper 完全同步；证书未确定仍显示「未准备」。
- **涉及文件**：`SigningCoordinator.swift`、`RenewalCoordinator.swift`、`SigningProgressView.swift`。
- **验证状态**：待 Xcode 编译 + 真机回归（重点：批量续签 Seal 自动回主页、单签不重复回主页；签名进度页显示真实序列号与详情页一致）。

### 2026-09-16 · 自续签 93%：自动回主页 + 安装转圈动效；连接设备并行化不再阻塞签名

- **现象**：签名/续签安装到 93% 后 UI 静止像卡死，要人手按 Home 才让 iOS 完成替换；签名/续签的「连接设备」环节单次也明显卡顿（哪怕只签单个 App）。
- **根因**：
  1. **93% 卡死感**：Seal 自续签=覆盖安装运行中的自己，iOS 只有等旧进程退后台才用新版替换；但进度 UI 把 `.installing` 定成静止 93%，没有任何动效反馈。
  2. **连接设备卡顿**：`signAndInstall` 在签名**前**同步 `installChannel.start()`，整段隧道诊断（reset + 18s RSD 握手 + 36×500ms 轮询）阻塞签名；签名所需的 UDID 其实配对缓存就有，根本不必等隧道就绪。
- **修复**：
  1. **自动回主页**：进入 `.installing`（上传完成哨兵 1.01 触发 `.pushing→.installing`）后，`SigningProgressView.onChange` 对 Seal 自续签自动 `suspend` 切后台（`NSSelectorFromString("suspend")`+`responds` 守卫，不可用则静默降级），installd 在后台任务保护下完成替换，结果由重开的新进程对账——不再手按 Home。
  2. **转圈动效**：Seal 自续签 `.installing` 阶段进度环改为持续转圈的「替换中」动效（`selfReplacementInstallingRing`），不再静止 93%。
  3. **连接并行化**：`signAndInstall` 隧道改 `Task { try await installChannel.start() }` 后台平行启动；签名 UDID 从配对缓存 `storedDeviceIdentifier()` 快速读取（描述文件只认 UDID 与隧道无关），无人工痕迹的首次未配对场景仍等一次隧道。安装唯一漏斗 `installSignedIPA` 开头 ensure 通道就绪（`!isReady() → start()`，命中 900s 缓存近乎零等待），覆盖缓存/新签/续签三条路径，避免 `install()` 因通道冷而直接抛 channelNotReady。
- **涉及文件**：`Seal/Features/Apps/SigningProgressView.swift`（转圈动效 + 自动回主页）；`Seal/Core/Signing/SigningCoordinator.swift`（连接并行化 + 安装漏斗 ensure 通道）。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证（重点：①Seal 自续签到 93% 转圈、数秒后自动回主屏完成替换、重开已是最新并自动确认；②单/批量签名「连接设备」不再停顿、签名完成即装；③普通 App 签名安装互不影响、不误触发自动回主页）。`suspend` 为私有 API，若系统不可用必须静默回退到旧「按 Home」路径，不得报错中断。
- **已知边界（已补齐）**：自动回主页原来只在**单 App 续签**的 `SigningProgressView` 触发；批量续签 Seal 走 `BatchRefreshView`，其 `progress` 回调只透传 `SigningStage`、接不到 1.01 上传哨兵，导致批量里 Seal 永远收不到 `.installing`。补齐方式：`installSignedIPA` 的 Seal 分支在 `submitPrepared` 上传完成（>1.0）时补发一次 `progress(.installing)`，`AppsViewModel.consumeBatchEvent(.appProgress)` 对 `app.isSeal && stage == .installing` 触发 `SelfInstallAutoBackground`（已改为 internal 供两处复用）。**注意**：Seal 自续签必然替换运行中的自己、进程会被新包终止，其后排队的续签项会一并中断（与手按 Home 相同），这是 Seal 自更新的固有语义。

### 2026-09-16 · 自续签安装卡 93%、连接设备卡顿、检查安装结果要手动——三处连点优化

- **现象**：用爱思签的 Seal（Bundle ID 已带 `.CT8QZ7352B`）能正常自续签，但安装停在 93%；只有手动退回主屏幕才真正完成替换。签名/续签都在「正在连接设备」环节卡顿。证书页的「检查安装结果」要人手点，不会自动确认。
- **根因**：
  1. **93% 卡顿**：Seal 自续签=覆盖安装正在运行的自己，iOS 只有等旧进程退到后台才用新版完成替换。MinimuxerInstallChannel 为不让 installation_proxy 连接被冻结而刻意不切后台，于是 `.installing` 阶段被定死在 93% 干等，直到手按 Home 触发 swap 才落盘。进度 UI 的「是否保持前台」提示在这个场景下正好说反了。
  2. **连接设备卡顿**：`MinimuxerInstallChannel.start()` 的设备标识缓存窗口只有 60s。批量续签在两次 start 之间每个 App 都要签名、申请描述文件，一超过 60s 缓存过期就整体重跑诊断（reset + 18s RSD 握手 + 36×500ms 轮询），于是每个 App 都要在「连接设备」重卡一次。
  3. **检查安装结果要手动**：自替换 `reconcile(…)` 在「当前进程 == 提交进程」时固定返回 `.awaitNextLaunch`，必须由「重新打开的新进程」在启动维护里对账结算；设置页只支持点按钮重读本地状态，没有等待确认态下自动刷新，等新进程结算完成后 UI 不会自己切到已完成。
- **修复**：
  1. 进度文案区分 Seal 自续签与普通续签：Seal 显示「进度走完后按 Home 回到主屏幕，iOS 会用新版替换；替换完再重新打开」（新增 `AppSigningPresentationHelpers.sealReplacementTip`），不再误导「保持前台干等」；`awaitingReplacementConfirmation` 的 detail 同步改为「回主屏幕让 iOS 完成替换，再重新打开，本页会自动确认」。
  2. `MinimuxerInstallChannel` 缓存窗口 `60s → 900s`（整场签名/续签会话），命中仍要求 `isReady()` 为真，设备真断了不会用到陈腐缓存。
  3. 设置页等待确认态 `.task(id: state)` 自动每 2s 重读 `refreshSelfManagementState`，新进程结算/关闭事务后本页自动切到已完成，保留「检查安装结果」按钮作兜底。
- **涉及文件**：`Seal/Features/Apps/AppPresentation.swift`、`SigningProgressView.swift`；`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`；`Seal/Features/Settings/SettingsViewModel.swift`、`SigningCertificateSettingsView.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证（重点：Seal 自续签 93%→退后台→重新打开→设置页自动确认；批量续签连设备不再逐 App 卡顿；「检查安装结果」无需手动）。注意：本改动未触碰自替换对账/结算核心语义，`reconcileAtLaunch`/`settle` 仍由启动维护的 `SelfAppRegistrar` 负责。

### 2026-09-16 · 签名模型改动后旧单测断言被替代行为，导致 CI swift-regression 红

- **现象**：推送签名三改动（身份识别放宽 / 单槽位证书接管 / Bundle ID 团队后缀）后，云构建 `swift-regression` 在 12m27s 失败（exit 65），而 `build-package` / `rork-sign-tests` 均绿。
- **根因**：`BundleIDMapperTests.requestedMainBundleIdentifierWins` 断言「requested 原样胜出」（旧行为）；`CertificateTakeoverPolicyTests.singleRemoteCertificateWithFreeSlotCreatesLocal` 断言「两槽位下 1 张远程证书仍视为有空槽→createLocal」（旧两槽位语义）。两处都被本次故意改动的核心语义取代，单测没同步，实现行为变了、测试仍验旧行为。
- **修复**：单测对齐新设计——① requested 不再原样胜出，改为「未带当前 team 后缀则换算成 recommended（自动补 `.seal.teamID`）、已带则原样复用、大小写不敏感」；② 证书接管改为单槽位语义，「空槽（无远程证书）→ createLocal」，删除旧「单张远程证书当空槽」用例（其场景已由 `fullSlotsWithOnlySignerBlocks` 覆盖）。
- **涉及文件**：`SealTests/Signing/BundleIDMapperTests.swift`、`SealTests/Signing/CertificateTakeoverPolicyTests.swift`。
- **验证状态**：提交 `c37b378` 推送后重跑，run 68 三 job 全绿（build-package 3m25s / swift-regression 13m49s / rork-sign-tests 2m49s）。IPA `Seal_1.1.16.ipa`（sha256 `1c824466…`）已落盘 `Desktop/Seal_IPA/` 并二次校验通过。

### 2026-09-16 · 自续签身份源改为 Keychain/描述文件推断——评估后回退（守卫拦截）

- **提议**：问题2 想对齐 SideStore，让自续签在 Mach-O 读不出真实 signer（第三方工具签的非标准结构）时，用「描述文件授权证书 ∩ 本机 keychain 私钥证书，恰好 1 张」兜底确认 Seal 签名者，从而不再卡 SEAL-CERT-232 / SEAL-SELF-105。
- **回退原因**：实现后 `Scripts/verify-release-safety.py` 立即 FAIL 两条 Seal 自保护断言——本库硬性纪律是**绝不用描述文件授权列表推断 Seal 签名者**（2026-09-15 真机变砖血教训：授权列表含「并未实际签名」的证书，推断会保护错证书）。细想确有致命场景：Seal 由第三方工具签名时，profile 授权可能同现「本机 keychain 有私钥的旧证书」与「第三方签名证书」，交集恰好 1 张会保护错旧证书，放行撤销真正在用的第三方证书 → Seal 变砖。**守卫拦得对**。
- **处置**：回退 ApplePortalSigningService（`resolveSigningIdentity`）、SigningCoordinator 一键全撤、自动盘活清理三处兜底改动，恢复「只信 `installedIdentity`（真实 CMS 签名者），读不出即停止/SEAL-CERT-230/`.unavailable`」的既有安全模型；删除临时 helper。守卫恢复 PASS（128 + 54）。
- **结论**：第三方工具签的 Seal 自续签，仍按要求走「电脑原签名工具覆盖安装」这一既有安全兜底（SEAL-CERT-232 恢复文案），不因本次问题2 放宽。若真要做 Keychain 身份源，需重新设计并过安全评审（如电脑覆盖前把签名身份正确留存进 keychain，而不是设备端拿 profile 授权列表推断）。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Core/Signing/SigningCoordinator.swift`（均已回退至基线）。
- **验证状态**：`verify-release-safety.py` PASS。改动未遗留，无编译期新符号。

### 2026-09-16 · Bundle ID 未带团队后缀导致跨设备互相占用

- **现象**：同一个（原始）Bundle ID 只要被某台设备/账号注册过，其他设备就无法再注册使用，报 `bundleIdentifierUnavailable`。
- **根因**：`BundleIDMapper.mainBundleID` 在 `requested` 非空时**直接原样返回**，不附加 `.seal.{teamID}` 后缀。UI 默认推荐值虽带后缀，但当用户手动输入、或沿用旧的 `preferredBundleIdentifier`（历史数据不带后缀）时，最终签名/注册的 Bundle ID 就没有「团队隔离后缀」。不同 Apple ID（不同 team）的设备就会用同一个字符串 bundle ID 去注册，先注册的占用后注册的。Apple 的 App ID 在团队维度隔离，靠后缀把不同账号签成不同字符串才能天然避免冲突。
- **修复**：`BundleIDMapper.mainBundleID` 对 `requested` 统一换算——已带 `.seal.{当前teamID}` 后缀（续签复用已安装 / UI 默认推荐）则原样保留；否则用 `BundleIDPolicy.recommendedBundleIdentifier(for:teamID:)` 统一附加当前团队后缀（会剥离多余 `.seal` 中间缀，避免 `xx.seal.seal.team`）。与上游 AltStore/SideStore「原始+teamID」策略对齐。
- **涉及文件**：`Seal/Core/Signing/BundleIDMapper.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）真机验证，重点核对首次签名、手动改 Bundle ID、同 Apple ID 多设备三种路径最终签名 ID 均带当前 team 后缀。

### 2026-09-16 · 合法第三方签名被误判为 inconsistentArchitectures

- **现象**：Sideloadly 的 bundle mangle / 爱思非标准结构产生的合法签名，`AppBundleSigningIdentityReader` 因 CodeDirectory 全量哈希校验失败而判 `inconsistentArchitectures`，Seal 读不出身份，连锁触发 SEAL-CERT-232 / SEAL-SELF-105，无法自续签。
- **根因**：`inspectWithRorkSign` 把「CMS 密码学校验 + CodeDirectory 哈希校验」作为识别身份的双重硬条件；第三方工具持有合法证书 CMS 签名，但修改了二进制结构导致代码目录哈希对不上，被误判为无法识别。
- **修复**：**仅放宽 CodeDirectory 全量哈希校验**——改为以「能读出一致签名证书 serial」为识别身份的依据（多架构 serial 一致才通过），CMS/哈希校验状态如实记入 evidence 供诊断；`readTarget` 的 `signerNotAuthorizedByProfile`（signer serial 必须落在描述文件授权证书内）校验保持不变，防误撤销自身证书的原始目的仍未放松。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`。
- **验证状态**：待 Xcode 编译 + 回归样本真机验证。

### 2026-09-16 · iloader 非标准签名导致 Seal 无法自续签

- **现象**：设备上续签 Seal 时，证书页读不出完整证书；点续签后弹出「无法确认当前 Seal 的签名证书」，恢复文案「先用电脑的原签名工具覆盖安装一次 Seal，再回来续签」。日志另出现 SEAL-SELF-105「无法确认当前 Seal 的签名身份」。
- **根因**：当前正在运行的 Seal 由 iloader 用非标准签名结构签名，主程序/网络扩展的真实 CMS 签名者无法被 `AppBundleSigningIdentityReader` 读出。身份读不完整 → 既不敢撤销（SEAL-CERT-232）、也不敢覆盖装自己（SEAL-SELF-105）。这是设备现实状态，不是代码 bug，且不能靠弱化身份校验绕过。
- **修复/处置**：电脑覆盖安装（不卸载），保持同一 Apple ID（sunuannian1@gmail.com）、Team（CT8QZ7352B）、主/扩展 Bundle ID 一致，改用能产出标准签名的签名工具。
- **涉及文件**：`Seal/Infrastructure/Renewal/AppBundleSigningIdentityReader.swift`、`Seal/Core/Renewal/SelfReplacementCoordinator.swift`。
- **验证状态**：待用户电脑覆盖安装后，回读新日志确认身份读取完整。

### 2026-09-16 · 证书轮换在无法确认 Seal 真实签名证书时仍撤销

- **现象**：续签 Seal 时，即使读不出运行中 Seal 的 signer，日志仍出现「证书轮换：撤销 …序列号，原因=无本机私钥，运行中Seal=否」，把唯一一张无本机私钥的证书当普通孤儿撤了，随后创建新证书签名，但安装被 SEAL-SELF-105 拦住。
- **根因**：`rotateCertificatesAndCreateIdentity` 未区分「签名/续签 Seal 本身」与「签名普通 App」。读不出 signer 时把 `sealActualSignerSerials` 置空，导致运行中 Seal 证书被误标为「运行中Seal=否」进入可撤销集合。
- **修复**：新增 `sealSignerConfirmed` 标志；`isSeal == true` 且读不出运行身份时，前置抛出 `SEAL-CERT-232`（无法确认当前 Seal 的签名证书），在撤销发生前就止步。普通 App 不涉及 Seal 身份，不受影响。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：`Scripts/verify-release-safety.py`（128 源码回归 + 54 变异）全过，CI build-package / rork-sign-tests / swift-regression 全绿；真机日志确认旧版误撤、新版已止步于 SEAL-CERT-232。

### 2026-09-16 · SelfReplacementFailure 被兜成笼统 SEAL-SIGN-500

- **现象**：自更新安装分支抛出的 `SelfReplacementFailure` 未被映射为 `ImportFailure`，被 `AppsViewModel.unexpectedSigningFailure` 兜成笼统「SEAL-SIGN-500」，用户拿不到可操作指引。
- **根因**：`SelfReplacementFailure` 四种 case（runningIdentityUnknown / bundleShapeChanged / localSigningIdentityUnavailable / candidateChanged）未做错误码映射。
- **修复**：在 `SigningCoordinator` 新增 `selfReplacementFailure(_:)`，映射为 SEAL-SELF-105～108，兜底 SEAL-SELF-109，标题统一「Seal 自更新中止」；自更新安装分支 try/catch 捕获并转 `ImportFailure`。
- **涉及文件**：`Seal/Core/Signing/SigningCoordinator.swift`。
- **验证状态**：提交 `edc7971`，CI build-package / rork-sign-tests / swift-regression 全绿，回归测试未破坏。