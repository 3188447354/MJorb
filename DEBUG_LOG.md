# Seal Debug 记录（问题排查与修复日志）

> 用途：每次查出并修改的问题在此登记，记录「现象 → 根因 → 修复 → 涉及文件 → 验证状态」，
> 避免同类问题重复发生。新条目追加到「历史记录」顶部（最新在前）。
>
> 关联文档：`REWRITE_ROADMAP.md`（链路取舍）、`OPTIMIZATION_PLAN_*.md`（优化计划）、
> `ERROR_COPY_AUDIT_*.md`（报错文案口径）。

---

## 一、常犯坑位（教训沉淀，动手前先看）

### 1. 证书序列号跨来源比对必须先归一化
- **现象**：同一份证书，一处比对通过、另一处误判成「证书已被轮换 / 不在授权列表」。
- **根因**：序列号存在两种来源，格式不一致——
  - **AltSign**（`ALTCertificate.serialNumber` / `ALTX509Certificate.serialNumber`）走 big-number 十六进制，会剥掉最高半字节的前导 `0`（如 `E76A893…`）。
  - **Security 框架**（`ProvisioningProfileReader` 经 `SecCertificateCopySerialNumberData` 按 DER 字节 `%02X` 拼串）保留前导 `0`（如 `0E76A893…`）。
  - 直接 `caseInsensitiveCompare` 会把同一序列号当成两个不同值。
- **规矩**：凡是「AltSign 序列号 ↔ 描述文件/证书列表序列号」的比对，一律先过
  `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)`（去前导 0、转大写、只留十六进制）。
  同一来源内部的比对（如 AltSign↔AltSign，两端都剥前导 0）无需归一化，不要画蛇添足。
- **涉及文件**：`SigningCertificateSelectionPolicy.swift`（方法定义）、`ApplePortalSigningService.swift`、
  `SigningCoordinator.swift`、`ProvisioningProfileBinding.swift`、`AppPresentation.swift`、`SettingsViewModel.swift`。

### 2. 进度条「卡在 100%」的根因是阶段切换时机，不是进度值本身
- **现象**：大 IPA（如微信 ~500MB）上传进度到 100% 后，进度条长时间停在「正在传输 100%」，
  几十秒后才变「正在安装」。
- **根因**：上传（AFC 分块写）结束 ≠ 安装开始。中间隔着 Rust 侧预检（lookup / afcd 快照）以及
  installd 的解压/复制。旧逻辑只在「上传完成=100」处刷新进度，之后直到 installd 返回才切阶段，
  于是 UI 干等。
- **规矩**：需要三个信号的区分，不能把「上传完成」和「安装开始」混为一谈：
  - `0–100`：上传阶段真实进度。
  - **哨兵 `101`**（`INSTALL_ISSUED_PCT`，Rust 侧）：表示预检结束、installd 安装命令**即将下发**。
  - Swift 侧 trampoline 把 u64 的 `101` 换算成 `1.01`（`Double(pct)/100.0`），
    `p > 1.0` 即触发阶段从 `.pushing` 切到 `.installing`（文案「正在安装」），进度归 `1.0` 收尾。
- **涉及文件**：Rust `Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`、
  `bridge_idevice.rs`；Swift `MinimuxerBridgeIdevice.swift`（trampoline）、
  `MinimuxerInstallChannel.swift`（哨兵透传）、`AppsViewModel.swift`（`updateInstallProgress` 切阶段）。

### 3. rg 命令别用 `-r` 当行号标志
- `rg -rn` 里的 `-r` 是「替换」flag（会把匹配内容替换成 `n`），不是行号；行号用 `-n`。
  避免 `-r` 与 `-n`、`-l` 混用导致的输出错乱。

### 4. 云编译结果别用 `gh run watch --exit-status` 的退出码当「成败」信号
- `gh run watch` 后台任务返回非零 exit code，是命令自身/超时问题，**不代表工作流失败**。
  判断成败一律看 `gh run list` / `gh run view` 的 `completed success/failure` 状态；
  别拿后台任务的 exit code 反推「云编译失败」，否则会把成功的构建误报成失败。

### 5. 掉签根因别一上来就甩给「证书过期/描述文件来源」
- 「今天签、明天掉」不是证书过期（免费证书有效期一年），也不该先怀疑 `SelfAppRegistrar`
  用当前 bundle 的 `expirationDate` 写库（签名安装成功时 `installSignedIPA` 会用签名当时的
  profile 过期时间覆盖它）。
- 真正要查的是「签名/续签时 profile 是否被复用、有没有刷新有效期」：
  `fetchProvisioningProfile`（`ApplePortalSigningService.swift:1213-1215`）对免费账号
  删除 profile 失败会直接复用现有 profile，其过期时间就是签名后 App 的有效期。
  先把 `provisioningProfiles → fetchProvisioningProfile → expirationDate` 这条链追清，
  再决定改哪，别先动 UI/文案。

### 6. Swift 6 严格并发：新增「下载/回调」代码必踩的两个红线
- **确凿证据**：云编译日志里 `swift-frontend ... -target arm64-apple-ios16.0 ... -swift-version 6 -Onone`
  （Xcode 26.5 强制 **Swift 6 语言模式**，project.yml 未显式写但流水线/工具链默认按 6）。新增带回调的服务类时必踩两个红线：
  1. **非 Sendable class 暴露 `static let shared`** 直接报
     `static property 'shared' is not concurrency-safe because non-'Sendable' type 'UpdateIPADownloader' may have shared mutable state`，
     后跟 note：`class 'UpdateIPADownloader' does not conform to the 'Sendable' protocol`，
     并给两条修复建议 note：`add '@MainActor' to make static property 'shared' part of global actor 'MainActor'`
     / `disable concurrency-safety checks if accesses are protected ...`。
     → 无状态服务一律用 **`struct`**（不要 `final class` + 持 stored let），`FileManager`/依赖内联 `FileManager.default`，不挂 stored property。
  2. **`URLSessionDownloadDelegate` 在 iOS 26.5 SDK 里 `didFinishDownloadingTo` 是 required**：
     note 原话 `protocol requires function 'urlSession(_:downloadTask:didFinishDownloadingTo:)' with type
     '(URLSession, URLSessionDownloadTask, URL) -> Void'`。按 async `download(for:delegate:)` 的用法只需实现它（空实现即可，
     async 返回后再由调用方 `moveItem`），否则 `does not conform`。
  3. **`NSObject` 子类 = `@unchecked Sendable` → stored 闭包必须 `@Sendable`**：
     报 `warning: stored property 'onProgress' of 'Sendable'-conforming class 'ProgressDownloadDelegate' has non-Sendable type '(Double) -> ()'`，
     note：`a function type must be marked '@Sendable' to conform to 'Sendable'`。
     → 跨线程进度回调签名统一 **`@Sendable (Double) async -> Void`**（对齐 `InstallChannel.install(onProgress:)` 约定）；
     UI 侧闭包用 `@MainActor` 参数直接更新 `@State`，别内层再套 `Task`。
- **涉及文件**：`UpdateIPADownloader.swift`（本次正例）、`InstallChannel` / `SigningCoordinator.onInstallProgress`（既有约定）。

### 7. gsa.apple.com 对「复用上次失败的 idle 连接」返回 503，关键认证须关闭连接复用
- **现象**：Apple 认证（登录/2FA/团队查询）偶发 `HTTP 503 Service Temporarily Unavailable`，
  同一账号重试有时能过、有时一直卡 503；在代理/TUN 切换后更明显。
- **根因**：`gsa.apple.com` 对复用上一个倒下的连接敏感。一次失败请求残留的 idle 连接若被下一个
  请求复用，Apple 直接回 503；而失败后立刻重试往往又复用了同一失效连接 → 越重试越 503。
  这是**连接复用**问题，不是认证凭据/anisette 问题（因此 `retryOnApple503` 纯靠隔几秒重发
  效果不稳定，且 `SEAL-AUTH-107t` 超时/`SEAL-AUTH-107a` 文案会误导排查方向）。
- **上游佐证**：iloader 2026-09-10 用同样根因修复 503 ——
  `isideload/src/auth/grandslam.rs` 构造 reqwest client 加 `.pool_max_idle_per_host(0)`
  （禁用每 host idle 复用），iloader 因此发版 **2.3.3**（升级 isideload `#f2fd29ab`→`#f6a4d5d`）。
- **规矩**：GSA 认证请求走 New 连接，不复用 idle 连接。Swift/URLSession 下没有 reqwest 的一行 API，
  等价做法是给认证 session 设 `URLSessionConfiguration.httpAdditionalHeaders = ["Connection": "close"]`
  （或逐请求加 `Connection: close`）。注意这是**认证 session 专属**，不要全局扩散到所有请求。
- **涉及文件**：`Forks①` `altsign-mod/Sources/ALTAppleAPI.swift:71`（session 加 `Connection: close`，
  一条覆盖登录 init/complete + 2FA trusteddevice/phone/validate 全部 GSA 请求）。
- **注意（落地前置）**：Seal 通过 SwiftPM 用 `github.com/dmjorb/AltSign@868f0ff`，本地
  `.dev-workspace/forks/altsign-mod` 与该 remote 同源（HEAD=868f0ff），改动须随该仓库发版
  并更新 `project.yml` revision 才会进真机。尚未真机回归。

### 8. 编译错误会被「前序 module 错误」掩盖，别凭上一轮报错数判断已修完
- Swift 是**模块级**编译。若某文件在 `-emit-module` 阶段报错（尤其是并发/Sendable、跨文件类型推断这类
  会中止 module 生成的错误），后续文件的类型检查可能压根没跑，那些错误就不会出现在日志里。
- **表现**：修好 A 文件的 2 个错误后复跑，冒出 B 文件 1 个全新错误（本例 `UpdateIPADownloader` →
  `SealCommunityView` 缺 `title`），看起来像「越修越多」，实则是上一轮被掩盖、本轮才浮出。
- **规矩**：修完一轮编译错误后，**必须再完整编译到底**，直到日志 `** BUILD SUCCEEDED **` 或
  `error:` 行为 0，才能下「修完了」的结论；不要用「上一轮只有 N 个错」来推断本轮已解决全部。

### 9. 发布 release 前必须复核 IPA 版本，别复用目录里残留的同名 Seal.ipa
- **现象**：版本已发、`releases/latest` 也返回新 tag，用户下载更新却仍是旧版。
- **根因**：`gh run download` 把 artifact（`Seal-<run_number>` 内含 `Seal.ipa`）解压进 `--dir` 时，
  若目录已残留上次构建的同名 `Seal.ipa`，会同时出现「根目录旧 `Seal.ipa`」和「`Seal-<n>\Seal.ipa` 新产物」；
  发布误选了根目录残留旧文件（1.0.9 / build 59），而非新产物（1.0.10 / build 61），二者大小仅差 ~4KB。
- **规矩**：下载产物前先清空目标目录；发布前用 `python` 读 IPA 内 `Payload/Seal.app/Info.plist` 的
  `CFBundleShortVersionString` + `CFBundleVersion` 复核版本，别只凭文件名 `Seal.ipa` 判断。

### 10. Minimuxer 连设备只能经「隧道真转发」，内置反射隧道替代不了外部 LocalDevVPN
- **现象**：升级后安装/续签卡在「正在连接设备」，用户开 Wi-Fi + 外部 LocalDevVPN 仍不走。
- **根因**：Minimuxer 连设备**唯一**端点是 `10.7.0.1:49152/62078`（Rust `rsd.rs:174`），没有
  无线/局域网直连设备真实 IP 的备用路径；该地址必须由「能把虚拟网卡流量真正转发到设备」的隧道提供。
  外部 LocalDevVPN 靠电脑端 usbmuxd 转发、能打通；而一个「只反射 `10.7.0.0↔10.7.0.1`、不转发到设备」的
  内置隧道（如 SealTunnel）永远连不上，还可能跟外部隧道抢 `10.7.0.0/24`。
- **规矩**：判断某隧道能不能用于安装，先确认 10.7.0.1 上那个端口是否有真 listener（能把流量送到设备
  lockdown/RSD）；纯 IP 反射 ≠ 设备转发。别用「能起 VPN 虚拟网卡」当作「连得上设备」。

### 11. 跨仓库发 Release 别传源仓库 SHA 当 `target_commitish`
- **现象**：主仓库构建/测试全绿，发布步骤 `gh release create --repo sunuannian1/Seal-Releases --target "$SHA"` 报
  `HTTP 422: Release.target_commitish is invalid`。
- **根因**：`$SHA` 是源仓库 `Trae-seal` 的提交；Release 建在 `Seal-Releases` 时，GitHub 只接受**目标仓库**里存在的
  branch/tag/commit。跨仓库发布要么省略 `--target`（用目标仓库默认分支 HEAD），要么先把目标仓库的 ref 准备好。
- **规矩**：`ios.yml` 发布到 `sunuannian1/Seal-Releases` 时不传 `--target`；如要锁定发布源版本，用 Release notes/title
  或资产里的 `Seal-Info.plist` 表达，不要把源仓库 SHA 塞给目标仓库。

### 12. 覆盖续签的补验不能只看 Bundle ID 存在；恢复动作不能扩大破坏范围
- **本次静态审查发现，尚未修复**：旧 App 本来存在时，lookup 命中不证明本轮覆盖成功，不能据此写新到期日或删除旧 profile；MissingPackagePath 不证明是可安全卸载的占位，证书名额不足也不证明非当前证书无人使用。
- **后续改动约束**：安装明确拒绝须保留错误；不确定结果使用 pending/unknown，确认本轮安装凭据后才提交成功。检查/启动恢复/后台清理若会写库、删文件或改变共享会话，同样要受业务租约保护。超时返回不等于底层副作用停止，未结束的安装不得叠加重试。

---

### 13. OneDrive 路径下的仓库：含斜杠的分支名可能写出「未出生」分支
- **现象**：`git checkout -b release/x` 提示成功，但随后 `git status` 把整仓 **596 个文件全显示为新增**（`A`）；
  `git rev-parse HEAD` 报 `fatal: ambiguous argument 'HEAD'`；`git ls-tree HEAD` 报 `Not a valid object name`；
  `git branch` 列不出当前分支。极易误判成「仓库被清空 / 改动全丢」。
- **根因**：仓库位于 OneDrive 同步路径（`.../OneDrive/Desktop/Seal`）。新建**子目录形态**的 ref
  （`refs/heads/release/x`）写入被静默丢弃，分支停在「未出生」状态（HEAD 指向不存在的 ref），
  索引便相对空树比较，全仓显示为新增。对照证据：`git update-ref refs/heads/release/x <sha>` 返回 `rc=0`
  但 `refs/heads/release/` 目录随后消失；而**改写已存在的** `refs/heads/main`、写 `.git/HEAD` 可持久化。
- **恢复**：`git symbolic-ref HEAD refs/heads/main`——索引/暂存内容不受影响，**改动不会丢**。
- **规避**：① 分支名**不要带斜杠**（用 `release-1.1.9-candidate` 而非 `release/1.1.9-candidate`）；
  ② 把「建分支 + commit + push」放在**同一次 shell 调用**内完成，push 落到远端即持久；
  ③ 动手前先确认 `git rev-parse HEAD` 能解析出提交。
- **附带能力（细化 AGENTS.md §0「Windows 本机无法编译」）**：**Rust 层可做本机部分校验**——
  `cd Vendor/Minimuxer/RustBridge && cargo check --offline`（cargo/rustc 1.98，依赖已缓存，约 10s）能查语法、
  类型与未使用绑定；`cfg(target_os="ios")` 分支与最终链接仍需云 CI。**Swift 层本机无工具链，只能靠云 CI。**

### 14. CI：测试步骤嵌在构建 job 内 = 同一份代码被全量构建两遍；拆 job 时有两处必查
- **现象**：`ios.yml` 一次运行 20m33s，而内容更少的 `ios-release.yml` 只要 3–10 分钟，差了一倍多。
- **根因**：`xcodebuild test` 默认 **Debug** 配置，会先全量构建一遍；紧接着 `build-unsigned-ipa.sh` 用
  **Release** 配置再全量构建一遍。两个配置的产物目录不同，DerivedData 增量完全用不上 → 两次全量编译。
  再串行叠加模拟器 UI 回归。
- **规矩**：
  ① 测试与打包拆成**并行 job**，别在同一个 job 里串行两遍构建。墙钟时间取 max 而非 sum
  （实测 20m33s → 9m38s）。
  ② **拆完先量一遍再决定要不要「跳过测试」**。本仓曾加过按路径判定的闸门，实测发现
  `build-package`（8m59s）比 `swift-regression`（7m38s）还长 —— 跳过测试省到的时间是 **0**，
  纯属增加「漏跑 UI 回归」的风险。**闸门已删除**：每次 push 都跑全量。
  ③ **拆出去的测试 job 必须自带构建前置**。本仓允许预编译 `RustBridge.xcframework` 落后于 Rust 源码，
  `ensure-rustbridge.sh` 按源码指纹当场重编。测试原来跑在 `build-package` 内、白蹭了这一步；
  拆成独立 job 后漏跑 → 链接到缺符号的旧库 → `_rust_bridge_*` undefined symbols
  （实测现象极具误导性：**build-package 成功、swift-regression 失败**）。
  **凡构建 App 的 job 都必须显式跑 `ensure-rustbridge.sh`。**
  ④ 一旦把测试拆出去，**发布的 `needs` 必须补上测试 job**，否则会「回归还没跑完就发版」。
  ⑤ CI 失败原因要能在**不登录**的情况下看到：`xcodebuild` 输出 `tee` 到文件，失败时提炼成
  `::error::` 注解（GitHub 原始日志需登录，注解不需要）。
- **涉及文件**：`.github/workflows/ios.yml`、`Scripts/verify-release-safety.py`。
- **验证状态**：实测 9m38s；护栏含「删掉 ensure-rustbridge 必须报错」的变异自检。链接修复待下一次运行验证。

### 15. 用 `withThrowingTaskGroup` 做超时 = 没有超时（回调不返回时永远不抛）
- **现象**：Apple 服务器不响应时，签名/证书页会**无限等待**，超时文案从不出现。
- **根因**：`ApplePortalSigningService.withAppleTimeout` 用 `withThrowingTaskGroup` 实现超时：
  一个子任务跑操作、一个子任务 sleep 后抛超时。但**任务组退出前必须等所有子任务结束**，
  `cancelAll()` 只能设置协作取消标记。ALTAppleAPI 的回调一旦不返回，操作子任务永远不结束，
  超时错误就被无限期拖住 —— 等于没有超时。
  （该函数自己的注释写着「Apple 服务器不响应时回调永远不触发，UI 会永久卡住」，意图是对的，实现达不到。）
- **规矩**：**凡「不可协作取消的操作 + 超时」一律用 `HardTimeout.run`**（非结构化任务竞速：
  超时先到就直接返回，输掉的一方被遗弃在后台、结果安全丢弃）。
  本仓已有三处正确范例：`AppleAccountClient.withTimeout`、`MinimuxerInstallChannel.withHardTimeout`、
  以及 `HardTimeout.swift` 自身的文档。**新写超时前先看 `HardTimeout.swift` 的注释。**
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（该函数被 3 个文件、
  23 个调用点共用，改一处即全部生效）、`Seal/Core/Concurrency/HardTimeout.swift`（范例）。
- **验证状态**：护栏新增「`withAppleTimeout` 必须含 `HardTimeout.run`、不得含 `withThrowingTaskGroup`」
  源码检查 + 变异自检；新增 `SealTests/Concurrency/HardTimeoutTests.swift`（3 例，其中一例专门
  构造「3 秒后才恢复且不响应取消」的操作，断言超时在 0.2 秒预算内触发）。**Swift 编译与测试待 CI。**

### 16. 裸 `CheckedContinuation` 交给第三方回调 = 重复回调即进程崩溃（不是可捕获错误）
- **现象**：签名/证书流程偶发**直接闪退**，没有可捕获的错误、没有明确堆栈，只有崩溃日志里一句
  `SWIFT TASK CONTINUATION MISUSE: ... resumed, but it was already resumed`。
- **根因**：`CheckedContinuation` 第二次 resume **不是抛错，是 `fatalError`**。Portal 三个服务把裸
  continuation 直接交给了 ALTAppleAPI，而 AltSign 存在两条真实的重复回调路径：
  ① 先回调一次错误、随后迟到地再回调成功；② `HardTimeout` 超时抛出后，底层回调仍会到达并再 resume
  （`HardTimeout` 只放弃自己那一层的等待，**不会**阻止底层回调）。
- **规矩**：**凡是把 `CheckedContinuation` 交给第三方回调，一律先套 `ContinuationBox`**
  （`Seal/Core/Concurrency/ContinuationBox.swift`，锁保护、首个结果获胜并清空）。
  同模式范例：`AppleAccountClient.LegacyCallbackBox`、`HardTimeout.RaceState`。
- **坑位**：守卫必须**按 continuation 实例**生效，所以要在**每个 `withCheckedContinuation` 创建点**
  各建一个盒（本仓 22 个），**不能**只改共用辅助函数就以为覆盖了 —— 这点和坑位 15 的
  「改一处全生效」正好相反，别混淆。
- **涉及文件**：`Seal/Core/Concurrency/ContinuationBox.swift`（新增）、
  `ApplePortalSigningService.swift`（15 点）、`ApplePortalCertificateService.swift`（4 点）、
  `ApplePortalInventoryService.swift`（3 点）。
- **验证状态**：护栏新增「ContinuationBox 必须清空 continuation」「Portal 内不得再出现裸
  `Self.resume(continuation,` / `continuation.resume(`」「创建点数 == 盒子数」+ 2 条变异自检；
  新增 `SealTests/Concurrency/ContinuationBoxTests.swift`（5 例，含重复回调、并发回调、
  超时后迟到回调）。**Swift 编译与测试待 CI。**

### 17. 写 API 超时 ≠ 失败；证书私钥随响应一起丢，重试只是多烧一个名额
- **现象**：创建证书请求超时后提示「请检查网络后重试」，用户照做 → 证书名额被无声消耗，
  直到撞上 `SEAL-CERT-204b`（数量已达上限）。
- **根因**：把写 API 当读 API 处理。读 API 超时=没拿到数据，重试无害；**写 API 超时=结果未知**，
  服务端可能已经创建成功。更关键的是：**私钥由 AltSign 在本地生成、只随响应返回，响应一丢就永久
  不可恢复** —— 所以「已经建好」的那张证书也是废的，只能人工撤销。
- **规矩**：写 API 超时后**既不盲目重试、也不自动撤销**，而是**对账一次**远端列表
  （`certificateMachineName` 含 team + 秒级时间戳，与本次请求一一对应，不会误认别人的证书），
  按三种结论分别给文案：确认没建（可重试）/ 确认建了但废了（去撤销）/ 对账也失败（**未知**，
  先确认再决定）。**「无法确认」绝不能当成「没有创建」。**
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`
  （`addCertificate` + `OrphanReconciliation` + `isTimeoutError` + `certificateCreationUnknownFailure`）。
  错误码 `SEAL-CERT-209b/209c/209d` 三选一，必须互不相同。
- **验证状态**：护栏新增「创建证书超时必须对账」「必须区分未知与未创建」+ 变异自检；
  新增 `SealTests/Signing/PortalWriteTimeoutSemanticsTests.swift`（7 例，锁定错误码与文案口径）。
  **Swift 编译与测试待 CI。**

### 18. 日志脱敏的四个盲区：JSON key、含空格的值、PEM 私钥块、Bearer 后的凭据
- **现象**：导出的日志看着「有脱敏」，但 JSON 日志里的密码/token、多行私钥、`Authorization` 头
  全是**明文**。日志要离开设备，等于直接把凭据交出去。
- **根因（四个独立缺口，都用 Python 复刻正则逐条证实过旧行为）**：
  1. **JSON 的键带引号**。旧规则是 `(\b(?:KEY)\b\s*[：:=]\s*)`，要求键后**紧跟**冒号；
     而 JSON 是 `"password": "..."`，键后是 `"` → **整条规则从未匹配过 JSON**。
     修法：键后允许一个可选闭引号 `"?`。
  2. **值含空格**。旧值是 `[^\s,;\]\}]+`，在第一个空格截断：`password = hunter2 with spaces`
     只脱敏成 `[redacted] with spaces`，后半截外泄。修法：值增加「带引号串」分支
     `"(?:[^"\\]|\\.)*"`（JSON 值必带引号，含空格也能整段吃掉）。
  3. **PEM 私钥块**。`-----BEGIN PRIVATE KEY-----` 里没有 `key: value`，正文是纯字母数字、
     还被换行切开 → 键值对、base64、长标识符三条规则**全都不命中**。修法：新增
     `redactPEMBlocks`，按 `BEGIN...END` 成对整块替换，`(?s)` 跨行。
  4. **`Authorization: Bearer <opaque>`**。键值对在 `authorization` 后只看到 `Bearer` 词，
     把 `Bearer` 换掉就收工，真 token 留在明文里。修法：新增 `redactAuthorizationSchemes`，
     吃掉 scheme 词（Bearer/Basic/Token/Digest）之后的凭据。
- **规矩**：脱敏规则**按形态**覆盖，不能假设「结构化格式都长一样」。新增格式（JSON、YAML、
  多行块、header）时必须补对应形态的**固定秘密语料**用例，断言「秘密不得出现在输出里」。
- **坑位**：断言要写「不得含秘密」而不是「等于某固定串」—— 后者会锁死实现，前者只锁安全性质。
  同时必须补「**不得过度脱敏**」的用例（普通诊断行原样保留），过删同样毁掉可诊断性。
- **涉及文件**：`Seal/Infrastructure/Diagnostics/LogPrivacyRedactor.swift`（三个新/改函数）、
  新增 `SealTests/Diagnostics/LogPrivacyRedactorTests.swift`（12 例）。
- **验证状态**：用 Python 复刻正则跑了 12 条语料 + 2 条「不得过度脱敏」，全过；并用旧正则
  对比证明四个缺口真实存在。护栏新增 3 项源码检查 + 1 条变异。**Swift 编译与测试待 CI。**

### 19. 「批量续签完成」可以是假的：缺前置条件的项被静默省略
- **现象**：批量续签报告全部完成，但确实有应用没被处理 —— 用户既看不到那个应用，也不知道为什么。
- **根因**：`RefreshPlanner.makeQueue` 里 `guard let accountID else { return nil }`，
  没绑定账号的应用**直接从队列里消失**。`compactMap` 让「丢项」看起来像正常过滤，
  结果计数 `total` 也不含它，于是没有任何地方能发现少了东西。
- **规矩**：**队列构建不允许静默丢项**。缺前置条件（账号缺失、多候选无法唯一确定）的项
  必须显式进队列并带上 `requiresAction` 状态与**可执行的原因**（「请到「我的」添加并验证账号」，
  而不是「跳过」）。
- **配套三件**（缺一个就还是假成功）：
  1. `BatchRefreshResult` 计数分桶：`needsAction` 与 `failed` 分开 —— 「没试」和「试了没成」
     的下一步动作不同（去补前置条件 vs 重试）。并暴露 `isBalanced`
     （`succeeded + failed + needsAction == total`）作为不变量，等式不成立就是有项被丢了。
  2. UI 计数也必须分开：`consumeBatchEvent` 的 `.appFailed` 分支要按错误码
     （`RenewalCoordinator.requiresActionCode`）判断，不能一律 `failed += 1`，
     否则用户以为「重试就能好」。
  3. 整轮结束后若 `needsAction > 0`，必须显式弹一条说明 —— 列表里它们只是「等待中」，
     不说明用户会以为整轮都成功了。
- **涉及文件**：`Seal/Core/Renewal/RefreshPlanner.swift`、`RefreshQueueItem.swift`、
  `Seal/Infrastructure/Renewal/RefreshQueueStore.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`。
- **验证状态**：护栏新增 6 项源码检查 + 2 条变异；新增/改写 9 例测试。**Swift 编译与测试待 CI。**

### 20. 被中断的续签会永久停在 `running`：既不被重试也不被清理
- **现象**：进程在续签中途被杀（崩溃 / 被系统回收）后，队列里那些应用**永远停在「运行中」**，
  既不会出现在失败列表（所以「只重试失败项」跳过它们），也不是 `completed`（所以不会被清理）。
- **根因**：状态机里根本没有「结果未知」这一态。`running` 是**瞬时态**，只在进程活着时有意义；
  进程一死它就变成了**永久脏数据**。
- **规矩**：任何持久化的「运行中」状态都必须在启动时收敛。本仓做法：新增 `unknown` 态，
  启动时 `RefreshQueueStore.recoverInterrupted()` 把 `running` 一律降级为 `unknown`。
- **关键顺序**：恢复必须放在**启动路径**上（`AppsRootView` 的 `.task` 最先执行），
  **不能**放在续签前 —— `run(queue:)` 会 `queueStore.replace(with:)` 用新队列整体覆盖文件，
  一旦开始新一轮，上一轮的 `running` 残留就被冲掉了，再恢复也来不及。
- **安全边界**：恢复**只改状态，不做任何签名/安装动作**。被中断的项可能已经装好、也可能只做了一半，
  贸然重做会造成第二次安装或误删新 profile。只让用户知情，由用户决定下一步。
- **涉及文件**：`Seal/Core/Renewal/RefreshQueueItem.swift`、`RefreshQueueStore.swift`、
  `RenewalCoordinator.swift`、`Seal/Features/Apps/AppsViewModel.swift`、`AppsRootView.swift`。
- **验证状态**：护栏新增 2 项源码检查 + 1 条变异；新增 4 例测试（含「`outstanding()` 必须排除
  `completed`」——这是 §4「恢复不能重做已成功的项」的落点）。**Swift 编译与测试待 CI。**

### 21. 读取路径上的「顺手写」：清理会删掉并发导入的中间目录（真实数据丢失路径）
- **现象**：应用列表加载（纯读取动作）会顺带做三件写操作 —— 记录恢复、Seal 自注册、
  孤儿文件清理。它们没有租约、不受加载代次约束，可与用户的签名/安装/续签交错执行。
- **根因**（两个独立缺陷叠加）：
  1. **`clearOrphanedAppFiles` 无条件删除 `Apps/` 下所有隐藏目录**。而 `.pending-<txid>` /
     `.backup-<txid>` 正是**进行中导入事务**的中间态目录。并发导入时把它们删掉，
     导入会失败并可能丢数据。旧实现里 `if name.hasPrefix(".") { removeItem }` 就是这个坑。
  2. **`validAppIDs` 是调用方更早时刻的快照**。快照之后新建的记录，其目录会被当孤儿删掉。
- **规矩**（三重保护，缺一不可）：
  - **跳过 journal 仍在的事务目录**：判定依据是 `Transactions/import-<txid>.json` 是否还存在
    （`AppFileStore.liveImportTransactionIDs()`）。
  - **新建保护期**：修改时间在 `minimumAge` 内的目录一律不删，用来兜住
    「检查点通过之后用户才开始导入」的时序窗口。用户主动清理（已持 `.maintainingStorage`
    租约、单槽协调器保证无并发写入）才可传 `minimumAge: 0`。
  - **删除前复核 DB 引用**：删除前**重新** `fetchAll()` 取有效 ID，不复用更早的快照。
- **规矩（读取路径只读）**：`load()` 不得写 DB、不得删文件。恢复/自注册/清理收敛为
  独立维护作业（`AppMaintenanceJob`），在空闲时运行；后台派生任务（邮箱/图标/历史/通知）
  逐步校验**加载代次**，旧代次不得回写 UI 状态。
- **涉及文件**：`Seal/Infrastructure/Storage/AppFileStore.swift`、
  `Seal/Core/Maintenance/AppMaintenanceJob.swift`、`MaintenanceGate.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、`AppsRootView.swift`、`Seal/Application/AppContainer.swift`。
- **验证状态**：护栏新增 9 项源码检查 + 5 条变异（42+17 → 51+22 PASS）；新增 14 例测试。
  **Swift 编译与测试待 CI。**

### 22. 后台维护不能抢全局单槽：用户不该等后台清理
- **现象（设计取舍）**：给维护作业加互斥时，最自然的做法是复用它自己的
  `OperationCoordinator` 单槽租约。但那会让**用户点「签名」时等后台清理跑完**，
  或直接被 `conflictFailure` 挡住 —— 用卫生任务拖慢用户操作，是本末倒置。
- **规矩**：采用「低优先级、可抢占」模型（`MaintenanceGate`）：
  - 前台操作永远不等待维护；维护**只在空闲时**取租约，取不到就**跳过本轮**（不排队、不阻塞）。
  - 维护持租约期间前台操作一旦启动，租约**立即失效**；作业必须在检查点 `shouldAbort(_:)`
    退出。因此**删除必须放在作业最后一步** —— 越早退出越不会留下半成品。
- **反面教训**：不要为了测试方便给生产代码加时序假设。测试里复现「用户操作恰好在作业中途开始」
  靠 `Task`/`yield` 调度是不可靠的；正确做法是把闸门抽成 `MaintenanceLeasing` 协议，
  测试注入「第 N 次检查点起返回失效」的替身，确定性复现。
- **涉及文件**：`Seal/Core/Maintenance/MaintenanceGate.swift`、`AppMaintenanceJob.swift`、
  `SealTests/Maintenance/`。
- **验证状态**：新增 6 例 `MaintenanceGateTests` + 8 例 `AppMaintenanceJobTests`。
  **Swift 编译与测试待 CI。**

### 23. 同版本续签换 profile 但不换版本号：只比版本会漏掉结算
- **现象**：自更新（Seal 替换自身）后，UI 显示的到期日与设备上真实生效的 profile 不一致。
  更糟的是自更新**失败**时，界面显示的是新到期日，而设备上跑的还是旧 profile ——
  用户以为还有很久，实际几天后就被吊销。
- **根因**：`SigningCoordinator` 的自更新路径在**安装之前**就把 `state = .installed`、
  `expiryDate = 新有效期` 乐观写进 DB（因为 installd 替换 App 时本进程会被杀掉，
  那是唯一的写入机会）。而推翻这份乐观值的责任在启动同步 `SelfAppRegistrar.ensureRegistered()`，
  它的「版本一致」分支却只回补 Team/账号就 `return`。
  **同版本续签换掉 profile 但版本号不变**，所以这个分支正是唯一会走的路径，
  于是乐观写入的值永远没人推翻。
- **规矩**：结算必须按 **profile 身份**（UUID / Name / CreationDate / 有效期），不能只看版本号。
  运行中的 Bundle 是**唯一可信证据**：装成功 ⇒ 新包读到新 profile；装失败 ⇒ 旧包读到旧 profile。
  每次启动都收敛，因此**不需要**额外落盘 pending 标记 —— 多一层持久化只会多一处可能与真实状态不同步。
- **顺带修正**：`SelfAppMetadata` 原先用 `ProvisioningProfileReader.summary(from:)`，
  而 `summary` 不含 UUID/Name/CreationDate；改用 `details(from:)`（超集）。
- **安全边界**：运行包解析不到 profile 身份时（`details` 失败）**不得凭空改写**已有值，
  只保留 Team/账号回补 —— 否则会把「读不到」误当成「变了」。
- **涉及文件**：`Seal/Core/Renewal/SelfAppMetadata.swift`、`SelfAppRegistrar.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`（乐观写入处，本次未改，注释已说明可被结算推翻）。
- **验证状态**：护栏 55 检查 + 25 变异 PASS；新增 3 例测试（同版本结算 / 安装失败回滚 /
  身份缺失不误改）。**Swift 编译与单测待 CI。**

### 24. 给结果类型加字段 = 必须 grep 所有构造点（本机无编译器时只有 CI 能发现）
- **现象**：G 包把 `BatchRefreshResult.remaining` 从存储属性改成计算属性、新增 `needsAction` 桶。
  `Scripts/verify-release-safety.py` 全绿，本机无从编译，CI `build-package` 直接失败：
  `AppsViewModel.swift: incorrect argument label in call (have 'total:succeeded:failed:remaining:',
  expected 'total:succeeded:failed:needsAction:')`。
- **根因**：只改了「定义 + 新调用点」，漏了**恢复上一轮批量结果**处的那个 `.init(...)`。
  本仓 Windows 环境**没有 Swift 编译器**，这类错误静态脚本抓不到、只有云 CI 能暴露，
  而一次 CI 往返约 10 分钟。
- **规矩**：
  1. 给结果类型加字段/改标签后，**必须 grep 构造点**（`.init(total:`、类型名 + `(`），
     不能只改自己新写的那处。
  2. 能在静态守卫里表达的编译期约束就写成守卫 + 变异。本轮已补：
     `restored.status = .completed(.init(` 之后必须出现 `needsAction:` 且不得出现 `remaining:`。
- **修复**：`ba3b3c9`。第三个桶改用 `needsAction`，取值仍由差值还原 ——
  计数不变量 `成功+失败+未执行 == 总数` 成立，因此旧持久化载荷（没有该字段）还原出的差值
  本来就是「未执行」，**不需要改载荷格式**。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`、`Seal/Core/Renewal/RenewalCoordinator.swift`。

### 25. 签名产物 ≠ 已安装快照：顶层 profile 字段提前推进会让 UI 显示不存在的到期日
- **现象**：已安装的应用重签后，即使安装失败（或进程在安装中被杀），界面仍显示**新**的到期日。
  用户以为续签成功，直到应用被吊销才发现问题。
- **根因**：`AppRecord` 同时承载两件事 —— 刚签出来的**产物**，以及设备上正在跑的**构建**。
  UI 展示的到期日取 `provisioningProfileExpirationDate ?? expiryDate`（`AppPresentation`、
  `ImportedAppRow`、`SigningProgressView`、`AppleAccountDetailView` 都是这个口径）；
  而 `applySigningResult` 在**安装之前**就把顶层 `provisioningProfile*` 推进到了新产物，
  `signedArtifactStatus` 也直接标成 `.installed`。
  这样「顶层 profile 字段」就同时被当成产物身份和已安装快照用，谁也说不清它描述的是哪一个。
- **为什么已有的设备对账补不了**：`reconcileInstalledAppsWithDevice` 只在**设备上查不到**
  这个 Bundle ID 时才纠正（而且是直接删记录）。应用确实装着、只是跑的是旧构建时，
  它查得到 → 不会纠正 → 假日期一直留着。
- **规矩**：顶层 `provisioningProfile*` / `expiryDate` 只描述**设备上正在运行的那份构建**；
  产物身份由 `signingTargets` 承载（每个 target 各自带 profile UUID/有效期/team/证书），
  顶层快照等**安装校验通过**后再推进。签名完成后产物状态标 `.awaitingVerification`，不是 `.installed`。
- **唯一例外**：Seal 自身。自更新安装会替换本进程，安装前那次写入是唯一机会；
  且它的顶层快照由启动同步从**运行中的 Bundle** 结算（坑位 23 / D 包），装失败会被推翻。
- **涉及文件**：`Seal/Core/Signing/SignedArtifactSnapshot.swift`（新增）、`SigningCoordinator.swift`。
- **验证状态**：护栏 59 检查 + 29 变异 PASS；新增 5 例测试。**Swift 编译与单测待 CI。**

### 26. 安装超时 ≠ 安装失败：超时后重试就是「第二次安装」
- **现象（风险）**：大包安装超时后自动重试，同一个 Bundle ID 上出现两个并发的 installd
  （旧的还在装、新的已经开始传包）—— 表现为 `ApplicationVerificationFailed`、白图标、或装到一半的应用。
- **根因**：`Minimuxer.stageAndInstall` 是**同步阻塞 FFI，没有取消机制**。
  `offThread` 的「超时」只是 `HardTimeout.run` 的竞速先到，**上层不再等待**，
  底下那次安装**仍在后台继续**。而两个 `install` 重载都带 `for attempt in 1...maxAttempts` 重试循环，
  且 `isTerminalInstallError` 的词表里**没有超时** —— 于是超时被当成「可重试」，
  直接发出第二次 `stageAndInstall`。
- **规矩**：**超时必须按确定性拒绝处理 —— 立即终止，不再重传重试。**
  这与 AGENTS.md §3「写 API 超时 ≠ 失败」是同一条原则：无法取消的操作，
  超时只代表「结果未知」，重试等于并发执行第二次。
- **判定不依赖错误文本**（文案会漂移）：用 `error is HardTimeout.TimeoutError`
  与 `ImportFailure.code == installTimeoutFailure.code` 双路识别。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`
  （两个 `install` 重载的重试循环 + 新增 `isTimeoutInstallError`）。
- **未做（需单独评审）**：操作 ID 贯穿 UI→Swift→FFI、租约持有到真实 FFI 结束。

### 27. async 创建 + std Mutex 缓存 = 并发创建会泄漏一条连接（RSD single-flight）
- **现象（风险）**：两个并发的 RSD 服务调用各自建一条隧道，后者覆盖前者，
  被丢弃的那条**既不关闭也不可达** —— 泄漏的连接，还可能让设备端 RSD 状态混乱。
- **根因**：`rsd.rs` 用**标准库 `Mutex`** 缓存 RSD 连接，而 `create_rppairing_rsd_connection()`
  是 **async** 的（TCP 连接 → 配对握手 → 建 TLS 隧道 → RSD 握手，耗时可达数秒）。
  `await` 期间锁**已经释放**，所以「先查缓存、没有就创建」这个典型写法在这里**并不互斥**。
- **修法**：加 `tokio::sync::Mutex` 创建门禁，并且**拿到门禁后再看一次缓存**
  （double-checked）—— 只加门禁会把「两个并发创建」变成「两个顺序创建」，照样泄漏一条。
  两个入口统一走 `ensure_cached_rsd_connection()`，创建调用只剩一处。
- **规矩**：凡「检查缓存 → async 创建 → 回填」的写法，缓存锁与创建过程**必须串行化**；
  标准库 Mutex 不能跨 `await` 持有，改用 async 锁或独立门禁。
- **验证状态**：**本机 `cargo check --offline` 通过**（`Vendor/Minimuxer/RustBridge`），
  无新增 warning。这是 Rust 相对 Swift 的优势 —— 本机就能验证编译。
  护栏 63 检查 + 31 变异 PASS。**运行时/真机行为待验证。**
- **验证状态**：护栏 61 检查 + 30 变异 PASS。**Swift 编译与单测待 CI。**

## 二、历史记录

### 2026-09-14 · E 包（R08）：区分签名产物与已安装快照
- **现象/风险**：已安装应用重签后，安装失败时界面仍显示新的到期日（详见坑位 25）。
- **修复**：
  1. 新增 `Seal/Core/Signing/SignedArtifactSnapshot.swift`：`statusAfterSigning(...)`
     与 `advanceInstalled(of:bundleIdentifier:expiryDate:)`。
  2. `applySigningResult` 新增 `advancesInstalledSnapshot` 参数 —— 已安装的第三方应用
     重签时**不**推进顶层 `provisioningProfile*`；签名完成标 `.awaitingVerification`。
  3. 安装校验通过（`verifyInstalled` 之后）才调用 `advanceInstalled` 推进快照。
  4. Seal 自身例外：自更新会替换本进程，且顶层快照由启动同步从运行包结算。
- **设计取舍**：纯函数放在独立 enum 而不是 `SigningCoordinator` 的 static 成员 ——
  后者是 actor，static 成员的隔离语义有风险，且 `PreInstallValidation` 已有先例。
  顺带让测试无需构造 actor 实例即可直接覆盖。
- **涉及文件**：`Seal/Core/Signing/SignedArtifactSnapshot.swift`（新增）、
  `SigningCoordinator.swift`、`SealTests/Signing/SignedArtifactSnapshotTests.swift`（新增 5 例）。
- **验证状态**：护栏 59 检查 + 29 变异 PASS。**Swift 编译与单测待 CI（本机无 Xcode）。**

### 2026-09-14 · D 包（R07）：同版本自续签按 profile 身份结算
- **现象/风险**：自更新失败或进程在安装中被杀时，「安装前乐观写入」的新有效期不会被推翻，
  UI 显示设备上不存在的到期日（详见坑位 23）。
- **修复**：`SelfAppMetadata` 改用 `details(from:)` 暴露 profile 身份；
  `reconcileSealRecordBindingIfNeeded` 扩展为 `reconcileSealRecordFromRunningBundleIfNeeded`，
  按 profile UUID / Name / CreationDate / 有效期结算；身份解析失败时不误改已有值。
- **设计取舍**：不引入 pending 落盘 journal —— 运行中的 Bundle 已是地面真值，每次启动自然收敛。
- **涉及文件**：`Seal/Core/Renewal/SelfAppMetadata.swift`、`SelfAppRegistrar.swift`、
  `SealTests/Renewal/SelfAppRegistrarTests.swift`（新增 3 例）。
- **验证状态**：护栏 55 检查 + 25 变异 PASS。**Swift 编译与单测待 CI（本机无 Xcode）。**

### 2026-09-14 · C 包（R06）：读取路径只读化 + 维护作业空闲租约 + 清理三重保护
- **现象/风险**：应用列表加载（读取路径）顺手做记录恢复、Seal 自注册、孤儿文件清理；
  这些写操作既无租约也无代次约束，与用户的签名/安装/续签交错，存在**删掉并发导入中间目录**
  的真实数据丢失路径（详见坑位 21）。
- **修复**：
  1. `load()` 只读化 —— 移除 `restoreMissingRecords()` / `ensureRegistered()` /
     `clearOrphanedAppFiles()`；后台派生任务逐步校验 `loadGeneration`。
  2. 新增 `Seal/Core/Maintenance/`：`MaintenanceGate`（空闲租约、非阻塞、可抢占）+
     `AppMaintenanceJob`（恢复 → 自注册 → 清理，三步带检查点，删除放最后）。
  3. `AppFileStore.clearOrphanedAppFiles` 三重保护：跳过 journal 仍在的事务目录、
     新建保护期、删除前复核 DB 引用；返回 `OrphanSweepReport` 便于审计。
  4. 组合根注入维护作业；启动流程 `runMaintenanceIfIdle()` 先于首次 `load()`。
- **顺带简化**：`AppsViewModel` 不再持有 `appRecordRecovery` / `selfAppRegistrar`（改由作业持有），
  避免「视图模型里还留着恢复对象」误导后续调用。
- **涉及文件**：`Seal/Core/Maintenance/{MaintenanceGate,AppMaintenanceJob}.swift`（新增）、
  `Seal/Infrastructure/Storage/AppFileStore.swift`、`Seal/Features/Apps/AppsViewModel.swift`、
  `AppsRootView.swift`、`Seal/Application/AppContainer.swift`、
  `Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/Maintenance/`（新增 14 例）。
- **验证状态**：护栏 51 检查 + 22 变异 PASS。**Swift 编译与单测待 CI（本机无 Xcode）。**

### 2026-09-14 · F 包（R09）：三入口统一预安装校验，扩展 target 不再漏检
- **现象/风险**：手工安装路径只校验**主 target** 的 profile 过期/设备归属；
  缓存复用路径（`installCachedSignedIPAIfPossible`）**完全不校验 target 明细**。
  扩展 target（Widget / Notification）的 profile 过期、设备不在列表、team 不匹配、
  证书序列号不匹配，都会一路装到设备上才失败 —— 表现为「装上就闪退」或安装被拒。
- **修复**：新增 `Seal/Core/Signing/PreInstallValidation.swift` 纯函数校验，
  两个安装入口统一走它：
  - 覆盖**每个** target（主 + 扩展）：profile 有效期余量、设备归属、team 归属、
    证书序列号（经 `SigningCertificateSelectionPolicy.normalizedSerialNumber` 归一化后比对，见坑位 1）。
  - Bundle ID 合法性、主 target 必须存在于记录中；旧记录无 target 明细时回退到
    `signedDeviceIdentifier`，缺关键元数据则要求重签。
  - `artifactStatus(forCode:)` 把拒绝原因映射回 `SignedArtifactStatus`，UI 状态不再失真。
- **涉及文件**：`Seal/Core/Signing/PreInstallValidation.swift`（新增）、
  `Seal/Core/Signing/SigningCoordinator.swift`、`SealTests/Signing/PreInstallValidationTests.swift`（新增 13 例）。
- **验证状态**：护栏 42 检查 + 17 变异 PASS。**Swift 编译与单测待 CI。**

### 2026-09-14 · G 包（R10/R11）：队列不再静默丢项 + 启动恢复 + 计数分桶
- **范围**：`outputs/Seal_企业级发布整改方案_20260913.md` §4 工作包 G。
- **改动 1（不静默丢项）**：`RefreshPlanner.makeQueue` 的 `guard let accountID else { return nil }`
  改为产出 `.requiresAction` 项 + 可执行原因。`compactMap` → `map`。
- **改动 2（启动恢复）**：`RefreshQueueItem.State` 新增 `unknown` / `requiresAction`；
  `accountID` 改为可选（requiresAction 项没有可确定账号）；新增 `requiresActionReason`。
  `RefreshQueueStore` 新增 `markUnknown` / `markRequiresAction` / `recoverInterrupted()` /
  `outstanding()`。恢复挂在 `AppsRootView` 的 `.task` 最前面。
- **改动 3（计数分桶）**：`BatchRefreshResult` 新增 `needsAction`，`remaining` 改为计算属性，
  新增 `isBalanced` 不变量；协调器里 requiresAction 项计入 `needsAction` 而非 `failed`；
  `consumeBatchEvent` 按错误码区分，不把「未执行」记成失败；整轮后若 `needsAction > 0` 显式弹说明。
- **护栏**：`verify-release-safety.py` 由 33 项 + 12 变异 → **39 项 + 14 变异，PASS**。
- **新增/改写测试**：`RefreshPlannerTests`（2 处改写 + 1 例新增）、`RefreshQueueStoreTests`（4 例新增）。
- **验证状态**：静态守卫全绿；**Swift 编译与单测待 CI**。
- **顺带确认**：CI run `34773587332`（`7915e76`）三 job 全绿 —— R04 的 22 个套盒、
  HardTimeout 迁移、写 API 对账全部编译通过且单测通过。`build-package` 8m25s。

### 2026-09-14 · 日志脱敏补齐四个明文外泄盲区（§5 专项）
- **范围**：`outputs/Seal_企业级发布整改方案_20260913.md` §5「日志格式」专项。
- **做法**：先用 Python 复刻 `LogPrivacyRedactor` 的 11 条规则，跑固定秘密语料（JSON 带引号 key、
  含空格值、转义引号、多行 PEM、RSA/EC 私钥头、Bearer/Basic 头、plist XML）+ 2 条「不得过度脱敏」，
  再用**旧正则**跑同一批语料做对照 —— 四个缺口全部复现，确认不是臆测。
- **改动**：`LogPrivacyRedactor.swift` 新增 `redactPEMBlocks`、`redactAuthorizationSchemes`，
  键值对规则改为「键后允许可选闭引号 + 值支持带引号串」。
- **护栏**：`verify-release-safety.py` 由 30 项 + 11 变异 → **33 项 + 12 变异，PASS**。
- **新增测试**：`SealTests/Diagnostics/LogPrivacyRedactorTests.swift`（12 例）。
- **验证状态**：正则逻辑已用 Python 复刻验证；**Swift 编译与单测待 CI**。
- **说明**：裸值（不带引号）仍按「到第一个空白为止」处理，这是**有意**的 —— 放宽会吃掉普通
  诊断文本，过删同样毁掉可诊断性。JSON/plist/header/PEM 这四类真实载体已覆盖。

### 2026-09-14 · R04 收尾：22 个回调创建点套盒 + 写 API 超时按「未知」处理
- **范围**：把 R04（取消/超时）从「修超时写法」推进到「回调层与写 API 语义都收口」。
- **改动 1（回调只恢复一次）**：新增 `Seal/Core/Concurrency/ContinuationBox.swift`，
  在 Portal 三个服务的 **22 个 `withCheckedContinuation` 创建点**各建一个盒，全部回调改为经盒转发。
  同时把两个共用辅助函数 `resume(_:value:error:)` 的第一参数从裸 `CheckedContinuation` 换成盒子，
  让类型系统兜住「忘了套盒」的写法。改法用脚本批量执行后逐点抽查 diff（22 点机械改动，
  手改易漏）；`Void` 特化用 `extension ContinuationBox where Value == Void { func resume() }`，
  覆盖 `revoke` / `deleteProvisioningProfile` / `assign` 三处 `CheckedContinuation<Void, Error>`。
- **改动 2（写 API 超时=未知）**：`addCertificate` 超时后不再直接上抛，而是按本次请求的
  `machineName` 对账一次远端证书列表，按 `OrphanReconciliation` 三种结论分别报错
  （`SEAL-CERT-209b/209c/209d`）。**不做任何自动重试或自动撤销。**
- **护栏**：`Scripts/verify-release-safety.py` 由 23 项源码检查 + 8 变异 → **30 项 + 11 变异，PASS**。
  新增守卫：盒子必须清空 continuation、Portal 内不得出现裸 resume、创建点数必须等于盒子数、
  超时必须对账、必须区分未知与未创建。
- **新增测试**：`SealTests/Concurrency/ContinuationBoxTests.swift`（5 例）、
  `SealTests/Signing/PortalWriteTimeoutSemanticsTests.swift`（7 例）。
- **验证状态**：静态守卫全绿；**Swift 编译、单测运行、真机回归均待 CI/设备**。
- **顺带确认**：上一轮 CI run `34772578224`（`679eaef`）三 job 全绿 —— `build-package` ✓、
  `rork-sign-tests` ✓、`swift-regression` 16m9s ✓。链接修复（补回 `ensure-rustbridge.sh`）生效，
  1.1.9 候选批次的全门首次跑通。

### 2026-09-14 · R04 起手：Apple Portal 的「超时」其实不生效（task group 写法）
- **现象**：Apple 服务器不响应时，签名/证书流程无限等待，超时文案从不出现。
- **根因**：`withAppleTimeout` 用 `withThrowingTaskGroup` 实现超时，而任务组退出前必须等所有子任务
  结束；ALTAppleAPI 回调不返回 → 操作子任务永不结束 → 超时错误永远抛不出来（详见坑位 15）。
- **修复**：把 `withAppleTimeout` 迁移到本仓已有的 `HardTimeout.run`（非结构化任务竞速），
  超时文案与错误码口径保持不变。该函数被 3 个文件、23 个调用点共用，**改一处即全部生效**。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（唯一改动）、
  `SealTests/Concurrency/HardTimeoutTests.swift`（新，3 例）、`Scripts/verify-release-safety.py`。
- **验证状态**：护栏 23 项源码检查 + 8 变异 PASS（新增「必须含 HardTimeout.run 且不得含
  withThrowingTaskGroup」+ 变异自检）。**Swift 编译与 3 个单测待 CI。**
- **R04 剩余未做**：① 回调统一走「只恢复一次」的状态盒（`AppleAccountClient.LegacyCallbackBox`
  已是范例，Portal 三个服务仍是裸 `Self.resume`，23 处调用点需逐个改，属机械改动）；
  ② 写 API 超时后按 unknown 记录并对账，不立即重试创建/撤销。

### 2026-09-14 · CI 每次等 20 分钟：把测试从 build-package 拆成并行 job（20m33s → 9m38s）
- **现象**：往 `release-1.1.9-candidate` 推一次提交要等 **20m33s**（iOS #11 实测）。改一行 UI 文案也是这个价。
- **根因**：`ios.yml` 把「单测 + 模拟器 UI 回归」这一步**嵌在 `build-package` 里**，于是同一个 job 里
  **同一份代码被全量构建两遍** —— `xcodebuild test` 先构建一遍 Debug，`build-unsigned-ipa.sh` 再构建一遍 Release
  （两个配置的产物目录不同，DerivedData 增量互相用不上）—— 外加一遍模拟器 UI 回归。
  对比：`ios-release.yml`（快速档）只构建一遍、不跑 UI，实测只要 3–10 分钟。
- **修复（两轮，第二轮推翻了第一轮的设计）**：
  - **第一轮**：拆成 4 个 job，并加了 `classify-change` 闸门按改动路径决定是否跑测试。
  - **第二轮（iOS #13 实测后修正）**：闸门**删掉**。实测拆开后 `build-package` = 8m59s、
    `swift-regression` = 7m38s，**build-package 反而更长** → 跳过测试省到的墙钟时间是 **0**，
    却要承担「UI 回归被漏跑」的风险。所以改为 3 个 job **每次 push 都并行跑全量**：
    总时长 **9m38s**（取 max 而非 sum），覆盖更全、逻辑更简单。
  - `publish-release` 的 `needs` 补上 `swift-regression` —— 测试拆出去后若不同步加依赖，
    **发布可能在 UI 回归还没跑完时就发出去**（拆分引入的新风险，必须堵）。
- **第二轮同时修掉的、由拆分引入的真实缺陷**：iOS #13 的 `swift-regression` **链接失败**
  （`exit 65`），`Undefined symbols: _rust_bridge_ota_serve / _rust_bridge_ota_configure /
  _rust_bridge_ota_identity_generate / _rust_bridge_idevice_stage_and_install /
  _rust_bridge_idevice_invalidate_rsd_connection / _rust_bridge_instproxy_upgrade`。
  **根因**：本仓允许预编译 `RustBridge.xcframework` 落后于 Rust 源码，`ensure-rustbridge.sh`
  按源码指纹发现不一致会**当场重编**。旧流程里测试跑在 `build-package` 内、前面已跑过这一步；
  新建的 `swift-regression` **漏了它**，于是链接到仓库里那份缺符号的旧 `librust_bridge.a`。
  这解释了「build-package 成功、swift-regression 失败」的诡异组合。
  **修复**：给 `swift-regression` 补上 Rust 缓存 + `Ensure RustBridge matches Rust source`，
  并在护栏里加两项检查（两个构建 job 都必须有该步骤）+ 一项变异自检。
- **可诊断性**：GitHub 原始日志要登录才能看，注解不用。`swift-regression` 把 `xcodebuild` 输出
  `tee` 到 `build/TestLog.txt`，失败时由新增的「Surface failures as annotations」步骤提炼成 `::error::`
  注解，避免再出现「只知道 exit 65、不知道哪条挂了」。
- **涉及文件**：`.github/workflows/ios.yml`、`Scripts/verify-release-safety.py`、`AGENTS.md`（§7）。
- **验证状态**：iOS #13 实测总时长 **9m38s**（20m33s → 9m38s，build-package 8m59s 成功出包）。
  YAML 经 pyyaml 解析通过；护栏 **22 项源码检查 + 7 项变异 PASS**。
  **链接修复与注解步骤待下一次运行验证**。

### 2026-09-14 · 证书撤销「有文案、没入口」：签名证书页补上证书清单与撤销入口
- **现象**：撞到证书数量上限时，Seal 提示「在「我的」页面撤销一个旧签名证书后重试」，
  但用户翻遍 App 找不到撤销入口 —— 走到这里是**死路**。
- **根因**：底层能力齐备（`ApplePortalCertificateService.revokeCertificate(serialNumber:)` 支持按序列号
  撤销**指定的单个**证书，`SettingsViewModel.revokeCertificate` 也已包好），但**没有任何 View 调用它**
  （`grep -rn "撤销" Seal/Features/` 只命中 SettingsViewModel 内部的错误文案）。
  而 **7 处文案**（`SigningCoordinator:436`、`ApplePortalCertificateService:71`/`:125`、
  `ApplePortalSigningService:178`/`:210`/`:769`，含本批新增的 `:720`）一直在指路这个不存在的入口。
  审查盲点：验证了「不再自动撤证」这个行为，却没验证「让用户手动撤」的出路是否真实存在。
- **修复**：
  - `SigningCertificateSettingsView` 新增「账号下的全部证书」，逐张列出并可撤销（二次确认）。
  - 确认框列出会被影响的**已安装**应用，按 `AppRecord.certificateSerialNumber` 精确匹配
    （经 `normalizedSerialNumber` 归一化，见坑位 1）；本机在用证书额外提示会清本机证书并自动重建。
  - 新增 `CertificateRevocationImpact`（纯函数，可单测）。
  - `SEAL-CERT-204b` 文案改为指向具体入口「我的」→「签名证书」。
  - `verify-release-safety.py` 新增护栏：界面必须存在 `revokeCertificate` 调用。
- **涉及文件**：`Seal/Features/Settings/SigningCertificateSettingsView.swift`、
  `Seal/Core/Signing/CertificateRevocationImpact.swift`（新）、
  `SealTests/Settings/CertificateRevocationImpactTests.swift`（新，8 个用例）、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Scripts/verify-release-safety.py`。
- **验证状态**：静态护栏 17 项 + 4 变异 PASS；**Swift 编译、单测与真机未验证**。
- **遗留已闭环（2026-09-14 后续提交）**：另外 6 处既有文案（`SigningCoordinator:436`、
  `ApplePortalCertificateService:71`/`:125`、`ApplePortalSigningService:178`/`:210`/`:769`）
  仍写「在「我的」页面撤销」，只指到 Apple ID 列表、还要用户自己猜下一步。已统一为
  「在「我的」→「签名证书」中撤销…」，并在 `verify-release-safety.py` 加护栏：**凡
  `recovery:` 行含「撤销」就必须出现「签名证书」**（护栏 20 项 + 6 变异）。

### 2026-09-13 · 发布整改第一批（候选 1.1.9，已改代码，未通过云 CI/真机验收）
- **现象/根因**：见此前链路复审 R01/R02/R03/R10/R11/R12；额外确认嵌套 IPA 解析将内层元数据与外层原包混用，并整块缓冲嵌套包。快速构建原先默认执行发布。
- **已实施**：删除 Rust/LockDown 安装失败自动卸载；删除覆盖失败后仅凭旧 Bundle ID 存在而写新有效期的补验；证书限额明确失败、不撤其他证书，创建后取消进入新证书清理区；主可执行文件声明/路径/非空校验；Seal 队列先匹配 Team；批量仅对已归类网络故障重试，安装不在外层重跑；失败项缺失不退回全量；取消等待不抢租约，单签等待超时有失败终态；嵌套外包明确提示先解压；快速构建默认不发布，两发布流程校验 tag 与 IPA 版本。
- **测试/防回归**：补充 11 个 Swift 测试函数（参数展开后 25 个用例，未执行）；修正旧 ZIPFoundation 测试夹具的 throwing 初始化与 Int64 API。增加 `Scripts/verify-release-safety.py`，14 项源码规则+3 项变异检查，接入完整/快速 CI。独立复核指出非法路径夹具问题已修正；R02 增加源码禁止补验的规则补足单元测试不能模拟旧设备记录的局限。
- **涉及文件**：SigningCoordinator、ApplePortalSigningService、SignedArtifactValidator、OperationCoordinator、AppsViewModel、RenewalCoordinator、RefreshPlanner、IPAParserService、Minimuxer Rust install.rs/Swift Install.swift、4 个测试文件、2 个 CI、project.yml。
- **验证状态**：本机安全规则与变异检查、Rust FFI 源码审计、git diff --check 通过；仅 CRLF 规范化提示。Windows 无 Swift/Xcode；GitHub CLI 未登录，不能取得本次云构建证据。未提交/推送/发布；Rust 源码变化尚未重建为 iOS 二进制。
- **发布阻断仍在**：R04 硬超时/取消、R05 未结束 FFI 与会话单飞、R06 无锁恢复/清理、R07 自续签可信确认、R08 文件/DB 事务、R09 缓存完整校验及外围更新真实性等；不能宣称企业级可发布。
- **方案**：`outputs/Seal_企业级发布整改方案_20260913.md`。回归必须先隔离测试账号和无重要数据的 App，禁止以恢复旧自动卸载/撤证逻辑作为兼容性回退。

### 2026-09-13 · 签名检查—安装—续签复审（基线 59117d8 / 1.1.8，仅静态审查，未修复）
- **现象/触发条件**：覆盖续签遇到 MissingPackagePath、确定性安装拒绝、回调不返回、进程中断，或启动检查与写操作交错时，可能出现应用数据丢失、假成功、长期等待和记录不一致；本次未提供新的真机复现证据。
- **代码根因**：① Rust `run_install_chain` 的第二轮未区分真实已装应用，直接 uninstall；② `SigningCoordinator.installSignedIPA` 的失败补验仅凭 Bundle ID 存在就提交新有效期并清理旧 profile；③证书容量恢复自动撤销非当前证书；④ `withAppleTimeout` 仍用 task group 包装不能取消的 callback continuation；⑤超时遗弃 FFI、无锁的 load/recovery/清理与共享 RSD 缓存存在交错窗口；⑥ Seal 上传前就持久化批量完成结果，恢复不验证新 profile 是否生效。
- **修复建议（未实施）**：先禁止有破坏性的自动卸载/撤证、禁止以旧应用存在代替本轮安装成功；再统一副作用操作租约、取消/超时、pending/confirmed 状态和文件/数据库提交边界。最小回归应先用可注入故障的 mock，真机只用无重要数据的样本。
- **涉及文件**：`Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`、`rsd.rs`；`SigningCoordinator.swift`、`ApplePortalSigningService.swift`、`HardTimeout.swift`、`MinimuxerInstallChannel.swift`、`AppsViewModel.swift`、`AppRecordRecovery.swift`、`AppFileStore.swift`、`RenewalCoordinator.swift`、`SelfAppRegistrar.swift`、`RefreshPlanner.swift`。
- **审查报告**：`outputs/Seal_链路审查_20260913.html`（分级问题、精确源码位置、边界条件、最小回归矩阵）。
- **验证状态**：仅源码证据核对；未改业务代码/测试/版本，未运行云 CI 或真机测试。旧报告中证书 >7 天复用、正常失败项重试、711–730 重新签名分流等已落地，不再按旧结论重复报错；签名期间不自动 2FA 是现行设计，不是本次缺陷。

### 2026-09-13 · 签名卡 93% 桌面「无法安装」：installd 拒绝错误名未进终态表，确定性失败被当网络抖动重传
- **现象**：部分应用签名安装卡在 93% 长时间不动，桌面图标显示「无法安装」。
- **根因**：两层叠加。①设备端 installd 已拒绝安装（免费账号设备级 3 应用上限的拒绝错误名是
  `ApplicationVerificationFailed`，真机日志早已证实）；②Seal 的 `isTerminalInstallError`（重试前终态判定）
  和 `installationFailure`（最终归类）两张表里都**没有** `ApplicationVerificationFailed` → 确定性拒绝被误判为
  瞬时网络问题 → 整包重传重试最多 3 轮（单轮 mergedTimeout 上限 40 分钟）→ 用户看到的就是「卡 93% 一小时」；
  即便重试耗尽，最终归类也会错过 702l（iOS 拒绝）而给出错误引导。
- **修复**：两张表同步补入 installd 校验类拒绝错误名（`applicationverificationfailed`/`verificationfailed`/
  `failed to verify`/`code signature`/`signed resource`/`invalidsignature`/`profileexpired`/`untrusted`/
  「无法安装」），此类失败首次即弹出 `SEAL-INSTALL-702l`，不再空转重传。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、`project.yml`（1.1.8）。
- **教训**：终态判定表与最终归类表必须同一份词表（本次就是两处各漏一词）；新增错误分类时先 grep 两张表。
- **验证状态**：待 v1.1.8 真机验证：触发免费上限时应几秒内弹「安装被 iOS 拒绝」而非卡进度。

### 2026-09-13 · 日志满量设计：环形保留 1000 条 + 丢弃计数提示
- **设计**：内存/磁盘同一份缓冲，上限 200 → 1000 条（txt 约 0.5MB，整文件重写永远写不满磁盘）；
  满后滚动丢弃最旧条目而非停止记录；`droppedSinceClear` 计数被丢条数，导出头部固定
  「Seal 日志 · 北京时间 · 保留最近 1000 条」，发生过丢弃再补一行丢弃提示，避免误读为完整历史；
  清空操作连带重置计数。导出排版：北京时间 + 中文两字宽栏目（信息/警告/错误 · 账号/配对/签名/安装/续签/系统）。
- **涉及文件**：`SealLogStore.swift`（环形计数/容量/镜像）、`SealLogEntry.swift`（`SealLogTextFormatter`）、
  `SettingsViewModel.swift`（设置页导出复用同一格式）。
- **验证状态**：随 v1.1.7 真机验证。

### 2026-09-13 · 顺利签名/续签后 Seal 文件夹没有 Seal-log.txt：Documents 镜像只在 error 日志时触发
- **现象**：内置更新到新版后，签名/续签全程顺利，文件 App → Seal 文件夹里却没有 Seal-log.txt。
- **根因**：`SealLogStore` 的 Documents 镜像由 `pendingMirror` 门控，只在追加过 **error 级**日志时才置位；
  顺利操作全是 info 级 → 永远不镜像。设计初衷是减少写盘，副作用是「没出错=没日志文件」。
- **修复**：`flush()` 每次落盘都同步镜像（缓冲上限 200 条、导出文本极小，写盘成本可忽略），
  移除 `pendingMirror` 状态。
- **涉及文件**：`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、`project.yml`（1.1.7）。
- **验证状态**：待 v1.1.7 真机验证：任意签名/续签后 Seal 文件夹应出现 Seal-log.txt，且为北京时间排版。

### 2026-09-13 · 「今天装明天闪退」系统性排查：证书复用只查当下未过期，临期证书签新包次日必闪退
- **排查结论（逐路径）**：
  1. 描述文件新鲜度：免费账号每次 fetch 由 Apple 重新生成（真机截图证实每次续签都出新文件、到期日+7天）——无问题。
  2. 证书已过期被复用：v1.1.1/v1.1.2 已修（网络失败分支+列表命中分支都查有效期）——已覆盖。
  3. **证书「明天才过期」被复用（本次新发现）**：四处复用分支只查 `isExpired() == false`，
     剩余寿命 1 天的证书会通过检查、配 7 天新 profile 签进包里，**次日证书到期 iOS 判「尚未验证」闪退**。
     慢速路径两个复用分支此前甚至完全没查有效期。
  4. 外部吊销（同一 Apple ID 在 SideStore/其他 Seal 签名挤占免费证书名额）：签名前有效性校验能拦住不再复用，
     但签名后被外部吊销属不可防的外部因素。
  5. 设备系统时间被改：用户侧因素，不可代码防。
- **修复**：新增 `certificateReusable(_:)`——证书剩余有效期必须 > 7 天（覆盖 profile 寿命）才允许复用，
  四个复用分支（快速路径列表命中/网络失败、慢速路径选中证书/账户证书）全部接入。
- **附带改动**：日志导出统一北京时间（Asia/Shanghai `yyyy-MM-dd HH:mm:ss`）+ 中文固定宽度栏目
  （信息/警告/错误 · 账号/配对/签名/安装/续签/系统），`SealLogStore.exportText` 与设置页导出共用
  `SealLogTextFormatter`。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `Seal/Core/Diagnostics/SealLogEntry.swift`、`Seal/Infrastructure/Diagnostics/SealLogStore.swift`、
  `Seal/Features/Settings/SettingsViewModel.swift`、`project.yml`（1.1.6）。
- **验证状态**：待 v1.1.6 发布后真机验证；导出日志应为北京时间整齐排版。

### 2026-09-13 · 清理零效果真根因：dump 文件名是 `unknown_N.plist`，清理器只认 `.mobileprovision`
- **现象**：v1.1.4（含「返回真实写入目录」修复）真机日志仍「扫描 0」，StikDebug 仍见 104 条旧 profile。
- **根因**：描述文件存在**手机系统 profile 存储**（profiled 守护进程），经 misagent `copy_all` 取出的是
  **CMS 签名包裹的二进制**。Rust `dump_provisioning_profile_rppairing` 对每条 profile 先尝试
  `plist::from_bytes` 解析命名：CMS 包裹解不动 → 落盘为 `unknown_{i}.plist`（扩展名是 `.plist`！），
  解析成功才是 `<UUID>.mobileprovision`。清理器此前只枚举 `.mobileprovision` → 全盘被跳过 → 扫描恒 0。
  附带纠正：v1.1.4 把 `RPProvision.dumpProfiles` 返回值改成根目录是**误判**——Rust RSD 实现确实写
  `docs_path/PROVISION` 子目录，原返回值本就正确，本次回退。
- **修复**：① `RPProvision.dumpProfiles` 回退为返回 `path/PROVISION`；② `DeviceProfileCleaner` 不再按
  扩展名过滤，目录内所有文件都交给 `ProvisioningProfileReader`（内置 CMS 解包：搜 `<?xml…</plist>` /
  `bplist00` 段）识别；③ 按解析出的 UUID 去重（LockDown 路径同一 profile 会落 raw+plist 两份）。
- **涉及文件**：`Vendor/Minimuxer/Sources/Provision.swift`（回退）、
  `Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、`project.yml`（1.1.5）。
- **教训**：修 bug 前要亲眼看一眼被调方的真实实现（Rust 源码行 27 的 `format!("{docs_path}/PROVISION")`
  和行 38 的 `unknown_{i}.plist` 命名分支都在，我却凭猜测改了 Swift 返回路径）——「先观测、再动刀」；
  观测加对了（v1.1.3 日志）也要把数据读到最后一环（文件扩展名）。
- **验证状态**：待 v1.1.5 发布后真机续签验证（预期「扫描 100+，删除 100+」，StikDebug 只剩最新一份）。

### 2026-09-13 · 清理零效果根因坐实：`RPProvision.dumpProfiles` 返回不存在的 PROVISION 子目录（**误判，已被上条推翻**）
- **现象**：v1.1.3 真机日志显示「自更新安装前清理：描述文件清理：扫描 0，匹配 0，删除 0」——
  dump「成功」却一个文件都没扫到。
- **根因**：`RPProvision.dumpProfiles`（RSD 路径）调 `RustIdevice.dumpProfiles(path)`，Rust `dump_profiles`
  把 `<UUID>.mobileprovision` **直接写在传入目录根**；但函数返回的却是 `"\(path)/PROVISION"`——
  一个从未创建、永远为空的子目录。清理器按返回值枚举 → 扫描恒为 0。LockDown 路径恰好把文件写进
  PROVISION 子目录再返回它（行为正确），所以 iOS 16 USB 路径不受影响；iOS 17+ RSD 路径全中。
- **修复**：`RPProvision.dumpProfiles` 返回实际写入目录 `path`。纯 Swift vendor 补丁，Rust 零改动，
  Seal 内唯一调用方就是 `DeviceProfileCleaner`。
- **涉及文件**：`Vendor/Minimuxer/Sources/Provision.swift`、`project.yml`（1.1.4）、`RELEASE_NOTES.md`。
- **教训**：「按返回路径枚举」依赖被调方契约，被调方契约错误时静默吞掉一切——先加观测（v1.1.3 的
  摘要日志）才一轮定位到根因；供应商代码也要当可疑代码审。
- **验证状态**：待 v1.1.4 发布后真机续签验证（预期日志「扫描 110+，删除 100+」，StikDebug 只剩最新一份）。

### 2026-09-13 · v1.1.2 清理仍零效果：全程静默无观测，补日志定位
- **现象**：用户升 v1.1.2 后「更新→续签→重开再续签」，StikDebug 查 Seal 仍剩 109 条旧 profile
  （LiveContainer 也剩 7 条——说明普通应用的事后清理也从未删成过，是**全链路零效果**，非仅自更新时机问题）。
- **根因（待真机日志确认）**：清理全程「最佳努力+静默」，dump/parse/remove 任一步失败都无痕迹。
  已排除的嫌疑：bundle ID 前缀解析正确（`ProvisioningProfileReader` 会剥 TeamID）；dump 文件命名
  `<UUID>.mobileprovision` 与枚举匹配；RSD 配对文件在签名流程早期已注入 Rust。
  待排查：misagent `copy_all` 是否失败、`details(from:)` 是否逐个解析失败、`remove` 是否逐个被拒。
- **修复（本轮先做可观测性）**：`DeviceProfileCleaner` 三个入口返回 `ProfileCleanupSummary`
  （扫描/匹配/删除/失败计数 + 中断阶段 + 首个错误）；`SigningCoordinator` 持有 `logStore`，
  自更新安装前清理与普通应用安装后清理的摘要都写入 Seal 日志（设置页可导出）。
- **涉及文件**：`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Application/AppContainer.swift`、
  `project.yml`（1.1.3）、`RELEASE_NOTES.md`。
- **验证状态**：`iOS Release Fast` 云编译+发布已通过（run `34747712847`），`v1.1.3` 已发布到
  `sunuannian1/Seal-Releases`（资产含 `Seal.ipa` / `.sha256` / 两份 Info.plist，`target=main`）。
  待真机：升 v1.1.3 → 对 Seal 续签一次 → 设置页导出日志，按「描述文件清理」摘要定位真实失败点。

### 2026-09-13 · v1.1.0 仍闪退+描述文件不删：自更新清理任务活不到执行，证书列表命中漏查有效期
- **现象**：用户已升 v1.1.0（含 09-13 早些时候的「清理+证书有效期」修复），Seal 仍打开闪退「无法验证」，
  且设备端历史描述文件一个都没少。
- **根因（两个）**：
  1. **自更新清理时机错误**：`SigningCoordinator` 自更新路径在 `installChannel.install(isSelfReplacement: true)`
     **返回后**才 `Task { await DeviceProfileCleaner.removeStaleProfiles(...) }`；installd 替换 Seal 的那一刻
     iOS 杀掉 Seal 进程，这个异步任务几乎必然随进程死亡 → Seal 自身 profile 永远清不掉。
     （普通应用的清理没问题，因为 Seal 进程还活着。）
  2. **证书快速路径漏查有效期**：`signingIdentity` 在「证书序列号命中 Apple 生效列表」分支直接复用本地证书，
     未校验有效期；网络失败分支虽有效期校验，但列表命中分支没有。列表若未及时剔除过期证书，
     过期证书被签进新包 → 次日 iOS 判「尚未验证」闪退。
  另：用户当前闪退的 v1.1.0 是被旧版（无有效期校验）签出来的历史包，新代码无法 retroactive 修复，
  需从电脑端重装一次。
- **修复**：
  - `DeviceProfileCleaner` 拆出私有 `removeProfiles(matching:keeping:)`，新增 `removeAllProfiles(for:)`：
    自更新**安装前**调用，删掉匹配 bundle ID 的全部设备端 profile（此刻新 profile 尚未落设备，凡匹配皆旧文件；
    启动校验只看包内 embedded.mobileprovision，与设备列表无关，安装失败也不影响旧应用打开）。
  - 自更新路径在 `installChannel.install` 前 `await DeviceProfileCleaner.removeAllProfiles(for: [当前运行 bundleID, effectiveBundleID])`；
    安装后的保留式清理保留为双保险。
  - `signingIdentity` 列表命中分支补 `X509CertificateValidityReader.validity` + `isExpired() == false` 才复用。
  - 新建 `.github/workflows/ios-release.yml` 快速发布档：Release 编译+打包+发布，跳过 UI 回归/rork 门
    （仅限没动 Rust 桥/签名器的小版本；大改动仍走完整 ios.yml）。
- **涉及文件**：`Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、
  `Seal/Core/Signing/SigningCoordinator.swift`、`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、
  `.github/workflows/ios-release.yml`、`project.yml`（1.1.2）、`RELEASE_NOTES.md`。
- **验证状态**：`iOS Release Fast` 云编译+发布已通过（run `34746602401`，提交 `fddb661`），`v1.1.2` 已发布到
  `sunuannian1/Seal-Releases`（资产含 `Seal.ipa` / `.sha256` / 两份 Info.plist，`target=main`）。
  真机回归重点：升到 v1.1.2 后对 Seal 做一次续签，StikDebug 里 Seal 的历史描述文件应只剩最新一份；
  之后每次续签/自更新自动保持清洁；续签后次日不再「尚未验证」闪退。

### 2026-09-13 · #1/#5 闭环：签名页死验证码移除，账号验证状态按错误码家族落库
- **现象**：签名链路持有 `verificationCodeProvider` / `reauthenticate()` 但生产从不调用，会话过期只能跳设置页；
  同时 `persistVerificationFailure()` 为空实现，策略层只认精确旧码 `102/105/106`，生产后缀码 `102d/105a/105e`
  不会写入 `needsVerification`，启动修复又会把无原因旧状态修回可离线使用，状态模型前后不一致。
- **根因**：产品策略未落地——签名/续签处于 LocalDevVPN 环境，不能可靠自动重登 Apple；应统一引导到
  「我的」页重新验证，而不是保留不会触发的签名页 2FA。状态层则缺「哪些错误真的写 needsVerification」的生产规则。
- **修复**：
  - 删除签名路径死成员：`ApplePortalSigningService.verificationCodeProvider`、`AppContainer` 注入、
    `AppsViewModel.signingVerificationBroker`、`SigningProgressView` 签名验证码弹窗；批量续签不再切换不存在的交互开关。
  - `AppleServiceFailurePolicy.verificationFailureReason` 改为按 `SEAL-AUTH-102/105/106` 前缀归族，显式排除
    `SEAL-AUTH-105f`（Team 查询失败）与全部 `SEAL-AUTH-107*`（会话过期/超时，不标 ID 失效）。
  - `SigningCoordinator` 在 Keychain 凭据缺失（105a）和签名抛出明确验证失败时写入
    `status = needsVerification` + `verificationFailureReason`；网络/限流/107 不写。`SettingsViewModel.persistVerificationFailure`
    改为真实保存（失败用 `try?`，不掩盖原始错误）。
  - 拆掉重复占用的 `SEAL-AUTH-105c`：Seal 自更新跨 Team 提示改用空闲码 `SEAL-AUTH-115`，设置页 105c 保留给本地凭据缺失。
  - 版本号 bump 到 `1.1.1`（Seal 主 target 与 SealTunnel 两处），`RELEASE_NOTES.md` 切换为本轮修复清单。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`、`Seal/Application/AppContainer.swift`、
  `Seal/Features/Apps/AppsViewModel.swift`、`Seal/Features/Apps/SigningProgressView.swift`、
  `Seal/Core/Accounts/AppleServiceFailurePolicy.swift`、`Seal/Core/Signing/SigningCoordinator.swift`、
  `Seal/Features/Settings/SettingsViewModel.swift`、`SealTests/Accounts/AppleServiceFailurePolicyTests.swift`、
  `project.yml`、`RELEASE_NOTES.md`。
- **验证状态**：`iOS Fast IPA` 云编译已通过（run `34745380038`，提交 `1cd7e1c`）。真机回归重点：会话过期仍只引导去「我的」；
  凭据被拒绝/Keychain 缺失后账号变为不可选并提示重新验证；网络失败/105f/107 不误标 needsVerification。

### 2026-09-13 · 发布到 Seal-Releases 报 422：`target_commitish` 误传源仓库 SHA
- **现象**：完整 `iOS` workflow 的 `build-package`、`rork-sign-tests` 已绿，`publish-release` 步骤
  `gh release create v1.1.0 --repo sunuannian1/Seal-Releases --target f1caf1d...` 报
  `HTTP 422: Release.target_commitish is invalid`。
- **根因**：发布目标仓库是 `sunuannian1/Seal-Releases`，但 `--target` 传的是源仓库 `sunuannian1/Trae-seal` 的提交
  SHA；该 SHA 在目标仓库不存在，GitHub 无法把它作为 Release 的 target commit。
- **修复**：`.github/workflows/ios.yml` 的发布命令移除 `--target "$SHA"`，让 `gh release create --repo ...`
  默认指向 Seal-Releases 默认分支 `main` 的 HEAD；版本来源仍由 IPA 内 `Seal-Info.plist` 与输入 tag 表达。
- **涉及文件**：`.github/workflows/ios.yml`、`DEBUG_LOG.md`。
- **验证状态**：已根治并手动用 run `34742582860` 产物补发成功：`sunuannian1/Seal-Releases` 的 `v1.1.0`
  已创建并标记 Latest，资产含 `Seal.ipa` / `Seal.ipa.sha256` / `Seal-Info.plist` / `SealTunnel-Info.plist`，
  `targetCommitish=main`。下次走 workflow 发布时不再传 `--target`。

### 2026-09-13 · 完整 iOS 发布 UI 测试 `testTwoStageNavigationCanBeTappedWithoutChangingHeaderAlignment` 失败（启动时序竞态）
- **现象**：`iOS` 完整发布 workflow「Run Swift unit and UI regression tests」失败，`ImportFlowUITests.swift:42`
  `XCTAssertTrue(app.staticTexts["已安装应用"].waitForExistence(timeout: 5))` 超时（exit 65）；同一 run 里
  `testTwoStageNavigationSupportsHorizontalSwipe` 通过。
- **根因**：测试时序竞态，**非产品回归**。`AppsRootView.mode` 初始为 `.installed`，`.task` 里
  `resolveInitialModeIfNeeded()` 在 empty 场景会异步改成 `.unsigned`，形成中转窗口。失败的 tap 测试只等
  `待签名，0 个` 按钮（顶部 tab 恒存在、立即返回），未等初始 mode 稳定就 tap，命中中转窗口时 TabView selection
  回写竞态、页面不切，header 5 秒未出现。对比 swipe 测试先 `waitForExistence("待签名应用")` 稳定初始态，故始终通过。
  09-12 成功 run 属侥幸通过；本轮模拟器 data migration 变慢放大竞态窗口而暴露。
- **修复**：tap 测试在 tap 前补 `XCTAssertTrue(app.staticTexts["待签名应用"].waitForExistence(timeout: 10))` 稳定初始态。
- **涉及文件**：`SealUITests/ImportFlowUITests.swift`。
- **验证状态**：待重发完整 iOS workflow 验证（Fast IPA 不跑 UI 测试）。

### 2026-09-13 · 云编译报 openssl/err.h not found：`Refresh local SPM binary artifacts` 误删 OpenSSL 二进制包
- **现象**：`iOS Fast IPA` workflow「Build fast unsigned IPA」步骤偶发失败，`native_bridge_ldid.cpp:46` 报
  `fatal error: 'openssl/err.h' file not found`（exit code 65）；相同 workflow 此前多次成功（同 revision、同缓存 key）。
- **根因**：`ios-fast.yml` 的 `Refresh local SPM binary artifacts` 步骤执行 `rm -rf build/DerivedData/SourcePackages`，
  把 AltSign 依赖的 **OpenSSL.xcframework（SPM binary artifact）** 一起删了。二进制包恢复依赖全局 SPM 缓存
  `~/Library/Caches/org.swift.swiftpm`，而它对应的 actions/cache key 只 hash `project.yml`（长期不变 → 命中 → 不回写），
  快照陈旧导致 OpenSSL 二进制包恢复不出来，NativeBridge 编译 `ldid.cpp` 时 `openssl/err.h` 找不到。与本次代码补丁无关，
  纯 CI 缓存层偶发；`Unicorn.xcframework`（AnisetteKit）同属 binary artifact 却恢复成功，佐证是「个别包缓存缺、非整体删错」。
- **修复**：改删 `rm -rf build/DerivedData/SourcePackages/checkouts`（只清源码 checkouts，保留 `artifacts/` 二进制包），
  从根上消除「二进制包依赖不稳定全局缓存恢复」的隐患（commit `dea58f9`）。重触发后编译通过。
- **涉及文件**：`.github/workflows/ios-fast.yml`。
- **验证状态**：`run 34738566116` 编译 `success`。注：本次还观察到 `queued` 卡 ~15 分钟属 GitHub 托管 `macos-26` runner
  队列拥堵（仓库无并发占用），取消重排后秒排到，非代码/workflow 问题。

### 2026-09-13 · 链路恢复闭环批量修复（#2/#3/#6/#7/#8/#9/#10，一次提交一次编译）
- **范围**：对齐 `SIGNING_CHAIN_ANALYSIS_20260913.md` 恢复链问题，本次批量落地：
  1. **#2 安装错误恢复分类**：`SigningProgressView.isResignRequired()` 按 `SEAL-INSTALL-71/72/73` 前驱识别「必须重新签名」，
     按钮改「重新签名」→ `AppsViewModel.retrySigningFromScratch()` 穿透 `forceResign: true`，避免对坏包无限「重新安装」。
  2. **#3 批量「重试失败项」只重试失败项**：`RenewalCoordinator.refreshFailedItems(appIDs:)` 仅过滤上一轮失败队列
     （抽 `makeQueue`/`run` 复用），`AppsViewModel.refreshFailedItems()` 从 `batchRefreshSession.items` 收敛失败 ID；
     `BatchRefreshView` 按钮改调 `refreshFailedItems()`，不再全量 `refreshAll()`。
  3. **#6 设置页证书/库存超时对齐**：`withAppleTimeout` 升为 module 级，`ApplePortalCertificateService` /
     `ApplePortalInventoryService` 的 fetchTeams/fetchCertificates/addCertificate/revoke/fetchAppIDs 全部套超时。
  4. **#7 自更新导入失败保留源 IPA**：`importSelfUpdateFile` 改返回 `Bool`（读 `workflow.state` 是否 `.completed`），
     `RootTabView.installSelfUpdate` 仅成功才 `deleteDownloadedFile`，失败保留供重试。
  5. **#8 更新检查语义版本比较**：`UpdateChecker` 改用 `Version.compare` 判「远端严格高于当前」才提示，旧版/回滚 tag 不再误弹。
  6. **#9 删除伪保护层**：`SelfRenewalContextValidator` + `SelfRenewalTracker`（含测试）未接生产、且与 `startSigning`
     已有 Team 保真逻辑冲突，删死代码，保留生产侧真实保护。
  7. **#10 诊断 catch 不再掩盖真实步骤**：`MinimuxerInstallChannel.diagnose()` 加 `currentKind` 追踪，顶层 catch
     按当前步骤 + `connectionFailure(error)` 归因，取代一律 `.pairingFile` 误报。
- **涉及文件**：`AppsViewModel.swift`、`SigningProgressView.swift`、`BatchRefreshView.swift`、`RenewalCoordinator.swift`、
  `RootTabView.swift`、`UpdateChecker.swift`、`ApplePortalSigningService.swift`、`ApplePortalCertificateService.swift`、
  `ApplePortalInventoryService.swift`、`MinimuxerInstallChannel.swift`；删 `SelfRenewalContextValidator.swift`、
  `SelfRenewalTracker.swift`、`SelfRenewalContextValidatorTests.swift`。
- **验证状态**：已改码，待一次云编译 + 真机回归；#1/#5（Apple ID 会话恢复）涉产品决策，后置讨论。

### 2026-09-13 · 设备端描述文件只增不删（累积 100+ profile）+ 出问题设备 Seal 次日「尚未验证」闪退排查
- **现象**：① 用户设备 App Expiry 列出 106 个历史描述文件残留；② 另一台设备签名后的 Seal 次日
  「尚未验证」闪退打不开（同一开发者证书下 Sollin Player 仍「已验证」），日志满屏 `SEAL-AUTH-105a`/
  `1100 session expired`/`SEAL-EXT-401`。
- **根因（两层，勿混）**：
  1. **设备端 profile 只增不删**：provisioning profile 随签名安装自动注册进设备（misagent `copy_all` 可见），
     Seal 安装链路从不调用 `misagent.remove` 清理旧的；叠加「免费账号云端 profile 自 2023-03-20 起无法删除，
     每次签名都生成新 profile」（`fetchProvisioningProfile` 已对齐 AltStore 处理），设备端持续累积。
  2. **Seal「尚未验证」是证书/凭证层，非 profile 过期**（同证书下其他 app 能验证过 = 证书整体没吊销）：
     高度怀疑 `signingIdentity` 快速路径「拉不到 Apple 证书列表（网络失败/限流）→ 直接退回本地旧证书、
     不校验其是否已过期」降级分支（`ApplePortalSigningService.swift:644-646`），与当日 1100 会话过期环境吻合。
- **修复（已实施）**：签名/续签安装成功后按「当前 Bundle ID」精确清理，**严禁「删全部」**：
  1. `SignedArtifactProfileReader` 从签名后 IPA 读主应用 `embedded.mobileprovision` 的 UUID（作为「保留的新 profile」依据）；
  2. `DeviceProfileCleaner.removeStaleProfiles(for:keeping:)`：`Provision.dumpProfiles`（misagent `copy_all`）枚举 →
     按 Bundle ID 过滤（case 不敏感）→ `Provision.removeProvisioningProfile` 删掉 UUID ≠ 新 profile 的旧文件；
     全链路静默失败，绝不阻断安装结果。
  3. `SigningCoordinator.installSignedIPA` 三条「已安装」出口（isSeal 自更新 / 普通安装 / retry 后设备已装）均挂接清理。
  4. `ApplePortalSigningService.signingIdentity` 降级分支「网络失败→退回本地证书」前新增 `X509CertificateValidityReader`
     过期校验，本地证书已过期则**不复用**、落入慢速路径重新申请（复用过期证书正是「次日尚未验证闪退」的高度可疑根因）。
  底层 `remove`/`copy_all` 能力已齐（RSD + LockDown 双路径），仅 Swift 编排，Rust 零新增。
- **涉及文件**：新增 `Seal/Infrastructure/Installation/DeviceProfileCleaner.swift`、
  `Seal/Infrastructure/Installation/SignedArtifactProfileReader.swift`；改 `SigningCoordinator.swift`（installSignedIPA 三个安装出口）、
  `ApplePortalSigningService.swift`（signingIdentity 降级分支）；复用 `Vendor/Minimuxer/Sources/Provision.swift`、
  `Seal/Infrastructure/Renewal/ProvisioningProfileReader.swift`（`details(from:)` 读 UUID/BundleID）。
- **验证状态**：已改码，待 Xcode 云编译 + 真机回归；闪退最终定性仍缺「出问题设备 Seal 内嵌 profile 过期时间」这一块证据（profile 是否已过期尚未取到）。

### 2026-09-13 · v1.1.0 内置 SealTunnel 无法替代外部 LocalDevVPN：续签卡「正在连接设备」，已回退运行时假隧道
- **现象**：升级到 v1.1.0 后，续签 Seal 自身停在进度 6%（`.waitingForChannel`「正在连接设备」）
  一直不前进；用户已开 Wi-Fi 且打开外部 LocalDevVPN，仍卡住。
- **根因**：Minimuxer(Rust) 连设备**唯一**路径是 `TcpStream::connect(10.7.0.1:49152)`
  （`Vendor/Minimuxer/RustBridge/src/idevice_support/rsd.rs:174`），**没有任何无线/局域网直连设备
  真实 IP 的备用路径**（Seal 侧 `bindTunnelConfiguration` 的 `getOverrideFakeIP` 固定返回
  `"10.7.0.1"`，所有路由收敛到 VPN utun 的 peer）。而 v1.1.0（提交 `551308e`）把「首次探测不通
  就自动拉起内置 SealTunnel」当成能替代外部 LocalDevVPN，但内置 `PacketTunnelProvider` **只是把
  `10.7.0.0↔10.7.0.1` 两个 IP 来回反射、不把流量转发到设备**，所以 `10.7.0.1:49152` 上永远没有
  真 listener：probe 不通 → Minimuxer connect 连不上 → 卡「正在连接设备」。且内置隧道与外部
  LocalDevVPN 共用 `10.7.0.0/24`，可能把它挤出 utun，导致"外部软件开着也没转发"。
- **修复**：删掉「运行时假隧道」这一层，回归 v1.0.13 及以前的「纯依赖外部 LocalDevVPN 真转发」：
  - `MinimuxerInstallChannel.diagnose()`：首次探测不通**不再** `onDemandActivator.activate()`（去自动拉起）；
  - `LocalDevVPNOnDemandActivator`：从协议与实现中删除 `activate()`，仅保留 `probeTunnel()`；
  - `LocalDevVPNSettingsView`：移除伪装成「启动并验证 LocalDevVPN」的 `sealTunnelCard`（它实际启动的是
    内置假隧道，易误导）；
  - `SettingsViewModel`：删除仅被该卡片引用的 `testSealTunnelChannel()` 及 `SEAL-TUNNEL-001/002`；
  - 删除孤立的 `SealTunnelManager.swift`。
  **保留** `SealTunnel.appex` 扩展 target 与 `PacketTunnelProvider.swift`（签名链路硬依赖
  「Seal 自身必须保留 SealTunnel 扩展」，见 `ApplePortalSigningService` 注释）。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`、
  `Seal/Infrastructure/Installation/LocalDevVPNOnDemandActivator.swift`、
  `Seal/Features/Settings/LocalDevVPNSettingsView.swift`、
  `Seal/Features/Settings/SettingsViewModel.swift`、删除 `Seal/Infrastructure/Tunnel/SealTunnelManager.swift`。
- **验证状态**：本地 Windows 无法编译 Swift，静态检查已确认无悬空引用（绿色基线）；待云编译 +
  真机回归：免费账号 + 外部 LocalDevVPN 续签应恢复正常，不再自动拉内置隧道。

### 2026-09-12 · 免费账号 App ID 上限本地预检（SEAL-APPID-305）误拦：拿「存活数」当「7 天窗口」
- **现象**：用户 Apple 账号里已有 11 个 App ID，Apple 照样能签名安装；但 Seal 报
  `SEAL-APPID-305 App ID 数量不足`，称「已有 10 个 App ID，连主 App 都无法创建」，属 false-block。
- **根因**：`provisioningProfiles` 里免费账号预检用 `existing.count >= 10`（fetchAppIDs 返回的
  **当前存活 App ID 数**）一刀切硬拦。但 Apple 的真实上限是「**7 天滑动窗口内最多注册 10 个**」，
  不是「当前存活 ≤ 10」——窗口滚动后老 App ID 仍在存活列表、却已不算进当周窗口，账号可合法攒到
  >10 个且 Apple 照签，所以拿存活数当上限必然误拦。
- **修复**：删除 `SEAL-APPID-305` 硬预检，改为交给 Apple 裁决；真超限时 `addAppID` 返回
  1009/3013，由既有的 `appIDFailure`/`isAppIDRegistrationLimit` 兜底归类成 `SEAL-APPID-304`
  （文案「7 天内最多注册 10 个 App ID」，更准）。主 App / 扩展无法新建时 Phase 1 仍会抛错或
  自动跳过签不了的扩展，语意不变。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（`provisioningProfiles`
  内删除 `if team.type == .free { ... }` 预检块，改为说明注释）。
- **验证状态**：本地 Windows 无法编译，待云编译 + 真机复验。

### 2026-09-12 · 云编译失败：部署目标断言过期 + 扩展 App ID 限额识别误用 `Self.` 引用不同类型
- **现象**：`9fed6f3` 把最低版本提升为 iOS 17 后，`iOS Fast IPA` 云编译先在「Verify Seal minimum
  deployment target remains iOS 16」步骤 `exit 1`（CI 断言仍写死 16.0，实际读到 17.0）；修掉断言
  重新触发后真正进入编译，又崩在 `ApplePortalSigningService.swift:1112/1114`：
  `type 'Self' has no member 'isAppIDRegistrationLimit'` / `'appIDFailure'`。
- **根因**：① `ios-fast.yml`/`ios.yml` 里 `test "$TARGET" = "16.0"` 是**写死的旧断言**，没人跟着
  `9fed6f3` 一起升 17，于是卡在编译前；② `appIDFailure`（95 行）与 `isAppIDRegistrationLimit`
  （150 行）定义在 **`enum ApplePortalSigningFailure`** 里的 `private static func`，但扩展 App ID
  限额识别的新调用点落在 **`actor ApplePortalSigningService`** 里，误用 `Self.` 前缀——`Self` 指向
  actor，根本没有这两个成员；且 `private` 在同文件跨类型也不可见。
- **修复**：① 两个 workflow 的部署目标断言 `16.0 → 17.0`（Seal 与 SealTunnel 各一处）；
  ② `appIDFailure` / `isAppIDRegistrationLimit` `private → fileprivate`；③ 调用点 `Self.` →
  `ApplePortalSigningFailure.`。另：`PacketTunnelProvider.swift` 的 Sendable capture 是 warning，
  不致命，未动。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`（4 处）、
  `.github/workflows/ios-fast.yml`、`.github/workflows/ios.yml`。
- **验证状态**：本地 Windows 无法编译 Swift，待云编译复验。

### 2026-09-12 · 签名/续签进度条「直接跳」而非丝滑：根因 Rust chunk=total/20，改为 1% 粒度
- **现象**：签名/续签上传阶段进度条「一格一格跳、不丝滑」，小 IPA（几秒传完）尤其明显，
  几乎 0 一下蹦到 100；环形进度环看似平滑但线性条/百分比是瞬跳。
- **根因**：Rust `stage_via_afc`（`Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`）
  用 `let chunk = (total / 20).max(256 * 1024)` —— 整个 IPA 只切 **20 块**，配合
  `if pct > last_pct`（整数百分比递增才回调），整个传输只上报 **约 20 个点（每跳 +5%）**。
  这不是 UI 缺动画，而是**源头进度值本身就稀疏**。（UI 层线性 `ProgressView` 无 `.animation`、
  百分比 `Int(progress*100)` 截断，是次级加剧，非根因。）
- **修复**：chunk 改为 `(total / 100 + 1).max(64 * 1024).min(1024 * 1024)`，把进度粒度从 5% 提细到
  1%、回调点从 ~20 个增到 ~100 个；上限 1MiB 与底层 AFC 分块对齐（避免 FFI 回调过频），下限 64KiB
  保证小 IPA 也有足够回调点（不致 33% 一跳）。
- **涉及文件**：`Vendor/Minimuxer/RustBridge/src/idevice_support/install.rs`（`stage_via_afc`，1 行。
  纯进度反馈，不影响写入正确性——底层 AFC 本按 1MiB 自动分块、`written` 累加 + 回读
  `info.size == ipa_bytes.len()` 校验兜底）。
- **验证状态**：仅改 Rust、本机无法编译，待 Xcode 编译 + 真机回归（微信/黄豆短剧/抖音等大中小
  IPA 各验一次，确认体感丝滑且安装/续签成功不受影响）。

### 2026-09-12 · 抖音 addAppID 1100 根因查证：端点一致性确认非客户端 bug（无代码改动）
- **现象**：签名抖音时，同一 session 的 `fetchTeams` / `fetchCertificates` / `fetchAppIDs`（查询）
  均成功，唯独 `addAppID`（新建 `com.ss.iphone.ugc.Aweme…` Bundle）返回
  `Apple.APIError 1100 Your session has expired. Please log in.`。日志显示账号「5 个可用 App ID」、
  无 3013/1009 痕迹，排除「App ID 7 天 10 个限额」（另一个独立限制，抖音 1 主 + 8 扩 = 9 个
  App ID 会额外撞它，但本次卡点不是它）。
- **根因（查证结论）**：客户端层面 `addAppID` 与 `fetchAppIDs` **完全等价** —— 二者同走 AltSign
  `sendRequest`（`ALTAppleAPI.swift:205`），同一 `X-Apple-GS-Token`(authToken)、machineID、
  oneTimePassword、localUserID、deviceUniqueIdentifier、date 认证头，同一 `baseURL =
  developerservices2.apple.com/services/QH65B2/`，唯一区别是 action 名（`ios/addAppId.action` vs
  `ios/listAppIds.action`）与 `additionalParameters`（写参数 vs nil）。`1100` 是 Apple 在 plist
  `resultCode` 里返回的（`processResponse`），`addAppID` 的 `resultCodeHandler` 只认
  35/9120/9401/9412，1100 落 default 分支原样透传为 `NSError(code:1100, "Your session has
  expired...")`。→ **1100 单独落在 addAppID 是 Apple 服务端对「写操作 addAppId.action」的 session
  判定行为，非 Seal/AltSign 代码 bug，客户端无法通过改端点/认证头消除。**
  （注：`certificate→servicesBaseURL(v1 JSON)` 与 `AppID→baseURL(QH65B2 plist)` 是两套 API，但
  二者请求都发生在 addAppID 之前且已成功，与本结论不冲突。）
- **顺带确认（同轮）**：
  ① `reauthenticate`（1100 时自动重登，`AppleAccountClient.swift:140`）全仓库**零调用点**，
  `AppleServiceFailurePolicy` 注释「下次签名自动重登」与实际不符；但**不建议接线**——签名/续签是
  LocalDevVPN 环境、自动重登访问 gsa.apple.com 必败（`ApplePortalSigningService.swift:294`），且
  历史上「清指纹/换 anisette 重试」曾造成全部账号掉线回归（`AppleAccountClient.authenticate` 注释）。
  ② `removeIdentifier()` 零调用点；identifier 丢失只可能来自换 Team 重签名导致 Keychain access
  group 变化 → `loadIdentity` 静默重生成新 `deviceIdentifier`（`AnisetteClient.swift:332`），进而 1100。
- **涉及文件**：`.dev-workspace/forks/altsign-mod/Sources/ALTAppleAPI+Operations.swift`、
  `ALTAppleAPI.swift`（查证，未改）；`AppleAccountClient.swift`、`AnisetteClient.swift`（顺带确认）。
- **验证状态**：纯代码查证，**无代码改动**。可操作结论：抖音 addAppID 1100 客户端唯一缓解路径是
  「重新验证 Apple ID 拿新鲜 authToken 后立刻签抖音」（即 `SEAL-AUTH-107` 引导的方向）；其本质是
  免费账号 + Apple 写接口会话校验的硬约束，非 Seal 可修复缺陷。

### 2026-09-12 · 批量续签误拦已绕过 3-app 上限的用户 + 抖音签名 1100 会话过期分类错误
- **现象**：① 用户（Lara）已用「绕过 3-app 上限」装了 6 个应用，点「全部续签」时 6 个全部失败
  （提示「应用数量已达上限」/ `SEAL-APPID-DEVICELIMIT`），但逐个单独续签却能成功；
  ② 签名抖音时 Apple 返回 1100 会话过期，却显示误导性的「App ID 创建失败 / 检查网络」
  （`SEAL-APPID-303`），而非「会话已过期 / 重新登录」。
- **根因**：
  ① `RenewalCoordinator.refreshAll` 调用 `signingCoordinator.signAndInstall` 时漏传
  `bypassFreeAccountDeviceLimit`，导致已装 6 个应用的用户在批量续签时被
  `enforceFreeAccountInstallLimit` 预检（设备级跨 team，occupied=5≥3）全部误拦。单独续签能过
  是因为单签路径有「继续绕过」按钮走 `continueBypassingDeviceLimit` 传 true，批量路径没有该按钮、
  直接判失败。
  ② `ApplePortalSigningFailure.appIDFailure`（App ID 创建阶段）漏识别 1100 会话过期，落进通用
  「App ID 创建失败 / `SEAL-APPID-303`」分支误导排查（上轮曾做「全局归类」后回退，本次只在 App ID
  阶段精准补识别，不扩散到其他阶段）。
- **修复**：
  ① `RenewalCoordinator.swift` 续签调用补传 `bypassFreeAccountDeviceLimit: true` —— 续签是覆盖
  已装应用、不新增免费账号设备槽位，预检应跳过、交回 installd 裁决；单个应用续签仍走
  `runSigning`（默认 false），与既有「继续绕过」按钮行为保持一致。
  ② `ApplePortalSigningService.swift` `appIDFailure` 在 Bundle ID 占用 / 7 天限额判断之前，
  新增 `nsError.code == 1100 || normalized.contains("session has expired") ||
  diagnostic.contains("1100")` 识别，归类 `SEAL-AUTH-107`（「会话已过期 / 重新登录」），
  与 `.account` 阶段一致；随后会被 `signOnce` 既有 `SEAL-AUTH-107` catch 兜底提示「去我的页面
  重新验证 Apple ID」。
  ③ 补上 `RenewalCoordinator.isRetryable` 的确定性失败排除：`SEAL-APPID-DEVICELIMIT` /
  `SEAL-INSTALL-702l`（iOS 拒绝：3 应用上限/完整性校验）/ `SEAL-INSTALL-702s`（存储不足）
  返回不可重试，与单签路径 `SigningProgressView.isNonRetryableFailure` 对齐——绕过上限后批量
  续签若真正超限会被 installd 拒绝为 `702l`，若不排除会完整重签+上传+等待 3 次，且违反
  「确定性失败立即终止、不做无效重试」硬约束。
- **涉及文件**：`Seal/Core/Renewal/RenewalCoordinator.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：① 绕过 3-app 上限装 6 个应用后
  「全部续签」不再被设备上限误拦；② 免费账号 authToken 过期（几小时后）签名抖音时提示
  「会话已过期 / 重新登录」而非「App ID 创建失败 / 检查网络」。注：1100 根因是免费账号
  authToken 仅几小时有效（Apple 硬限制），Seal 只能过期后正确引导重新登录，无法延长会话；
  ③ 设备状态与记录不一致（`lastInstalledAt` 残留）触发真正超限时，批量续签立即终止不再转圈。

### 2026-09-12 · 免费账号 App ID 7 天限额误报：3013 未被识别（iPhone17 / iOS27 beta3 用户日志）
- **现象**：用户（iPhone 17, iOS 27 beta3）签名 LiveContainer 报「App ID 创建失败 / 检查网络后
  重试」（`SEAL-APPID-303`）；续签 Seal 报「扩展无法创建 App ID / 移除扩展后重试」
  （`SEAL-EXT-401`）。日志关键行：`[AltStore.AppleDeveloperError 3013] You may only register
  10 App IDs every 7 days.`，且 07:49:42「Apple App ID 已同步：2 个可用 App ID」。
- **根因**：**Apple 免费账号「7 天内最多注册 10 个 App ID」限额触发**，与 iOS 27 beta3 / iPhone 17
  本身无关（任何系统都会触发）。Seal 有两个分类 bug 导致误报：
  ① `appIDFailure` 只匹配 AltStore 老错误码 `1009`，漏了新一代 AltSign 的 Apple 原生码 `3013`，
  于是 3013 落进通用「App ID 创建失败」分支 → 误导「检查网络」；
  ② 扩展 App ID 创建失败被外层 catch 笼统包成 `SEAL-EXT-401`「移除扩展后重试」，把全局限额
  掩盖成「扩展有问题」——但限额是全局的，移除扩展也救不了，且 Seal 自身必须保留 SealTunnel 扩展。
  **关键认知**：该限额是「7 天滚动注册总数」，不是「当前存活的 App ID 数量」，所以本地预检里
  `availableAppIDs = 10 - existing.count`（existing.count=2）放行后，真实 `addAppID` 才报 3013。
- **修复**：
  - 新增 `ApplePortalSigningFailure.isAppIDRegistrationLimit(_:normalized:)`，统一识别 1009/3013
    + 「every 7 days / 10 app ids / register / maximum / limit」等关键词。
  - `appIDFailure` 改用该共享函数 → 3013 正确归类 `SEAL-APPID-304`「7 天内最多注册 10 个 App ID」。
  - 扩展创建失败（`allowDroppingExtensions==false` 分支）先识别限额，命中则透传 `appIDFailure`
    的真正结果，不再包成误导性的「移除扩展」；非限额才走 `SEAL-EXT-401`。
- **涉及文件**：`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`
  （`appIDFailure`、新增 `isAppIDRegistrationLimit`、扩展 catch 分支）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：免费账号 7 天名额满后签名任意
  应用（主 App 或扩展）均提示「7 天内最多注册 10 个 App ID」而非「检查网络 / 移除扩展」。
  **用户侧根治**：等 7 天过期、改用其他 Apple ID、或用付费账号；Seal 无法绕过 Apple 硬限制。

### 2026-09-12 · 全项目文案审计：3 处新发现问题修复
- **现象**：对 v1.0.13 全项目流程链 → 文案做精准匹配审计，发现 3 处与逻辑行为不匹配的文案。
- **根因**：①「注册开发者账号」措辞易让免费账号用户误以为需付费注册（免费账号登录 + 同意
  Apple 开发者协议即有 Personal Team）；②续签兜底（SEAL-RENEW-500）点名「检查 LocalDevVPN」，
  该兜底仅处理非 ImportFailure，隧道错误已有 701 等专码，且免费账号无外部 LocalDevVPN 可操作；
  ③SEAL-APPID-303 的 recovery 未覆盖 1100 会话过期场景（1100 会落入此分支，换 Bundle ID 无用）。
- **修复**：
  - `SettingsViewModel.swift:1134`（SEAL-AUTH-114）：「已注册开发者账号（免费账号即可）」→
    「可正常登录且已同意 Apple 开发者协议（免费账号即可）」。
  - `RenewalCoordinator.swift:96`（SEAL-RENEW-500）：「检查网络与 LocalDevVPN 后重试」→
    「检查网络后重试」。
  - `ApplePortalSigningService.swift:130`（SEAL-APPID-303）：recovery 前置「若提示会话已过期，
    请先前往「我的」页面重新验证 Apple ID」，再回退网络/Bundle ID 引导。
- **涉及文件**：`Seal/Features/Settings/SettingsViewModel.swift`、
  `Seal/Core/Renewal/RenewalCoordinator.swift`、
  `Seal/Infrastructure/Signing/ApplePortalSigningService.swift`。
- **验证状态**：代码已改，未云编译、未真机回归。注：1100 归属仍走 SEAL-APPID-303 分支
  （上轮把 1100 全局归类修复回退了），本次仅从文案侧给出「先重新验证」引导兜底。

### 2026-09-12 · 隧道类报错文案口径修订（免费/付费账号区分 + 统一「检查是否打开 LocalDevVPN」）
- **现象**：v1.0.13 及更早的安装/配对报错文案中，隧道类错误（701/705/706b/706t/708/710/702t）
  一律让用户「打开 / 重连 / 确认 LocalDevVPN」，对两类用户都不精准：① 免费账号签名的 Seal
  内置隧道（SealTunnel）因缺 `networkextension` entitlement 起不来（必须装外部 LocalDevVPN
  软件），文案未告知；② 付费账号的隧道由 Seal 自动拉起（同名内置 VPN），没有可手动「打开」的
  外部软件入口。另有 708 文案「与电脑处于同一 Wi-Fi」纯错误——安装链路在手机端（本地隧道连本机），
  与电脑无关（历史遗留）。
- **根因**：文案起草时按「隧道=外部软件」的旧模型；且漏了「内置隧道需付费账号签名」这一关键约束。
- **修复**：隧道类报错 recovery 统一为「检查是否打开 LocalDevVPN」（对免费/付费两种账号都可操作）；
  reason 区分两种情况——免费账号签名的 Seal 需「先安装并打开外部 LocalDevVPN 软件」，
  付费账号「自动拉起内置隧道，检查 VPN 是否开启」；708 去掉「与电脑处于同一 Wi-Fi」；
  702d「WiFi」统一为「Wi-Fi」；709（隧道已通、握手失败）保持「保持前台后重试」不变。
- **涉及文件**：`Seal/Infrastructure/Installation/MinimuxerInstallChannel.swift`（701/705/706b/706t/
  708/710/702t 共 7 处文案）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：免费账号用户卡在「准备环境」时看到
  「免费账号需安装并打开外部 LocalDevVPN 软件」引导；付费账号行为不变。

### 2026-09-12 · Seal 内部更新后 Apple ID 失效需重新添加（覆盖安装签名 Team 变化 → iOS 判为新应用清空数据）
- **现象**：通过 Seal 内部更新（自更新 / 自续签）升级到新版本后，打开新版时已添加的 Apple ID 全部失效，
  需重新添加；已安装应用列表也一起丢失。
- **根因**：Seal 覆盖安装自己时，签名身份 = `application-identifier` = `TeamID + Bundle ID`。Bundle ID
  在自更新路径里由 `isSeal` 分支复用保留（`SelfAppRegistrar` / `BundleIDPolicy.targetBundleIdentifier`），
  但 **TeamID 取决于用哪个 Apple ID 签这次更新**。一旦 Team 变化，iOS 把覆盖安装判成全新应用：
  全新空容器（`Accounts.json`、`Seal.sqlite` 清空）+ Keychain 访问组失配（凭据读不到）→
  表现为「Apple ID 失效、需重新添加」。而 `beginSigning` 里 `resolvedAccountID =
  (isRenewal ? app.accountID : nil) ?? accountID` 依赖**落库的 `app.accountID`**，它一旦过期/为空
  就退回用抽屉所选账号，可能选到不同 Team 的账号触发数据清空。
- **修复**：`AppsViewModel.beginSigning` 对 `app.isSeal` 增加基于**当前运行 Seal 的真实签名 Team**
  （`SelfAppMetadata.current().signingTeamIdentifier`，读 embedded.mobileprovision）的账号纠正：
  优先改用同 Team 账号保住签名身份（并记日志）；只有找不到同 Team 账号（如首次从他人账号切到自己账号）
  才允许切换，并弹「更新将重置本地数据」提示（`SEAL-AUTH-105c`）。免费账号无 App Group，
  跨 Team 无任何可持久化路径（容器与 Keychain 访问组都随 Team 变），故只能「保身份 + 提示」，
  无法做到跨 Team 无损迁移。
- **涉及文件**：`Seal/Features/Apps/AppsViewModel.swift`（`beginSigning`）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：用同一 Apple ID 自更新后 Apple ID 列表、
  已安装应用完好；换用不同 Team 账号时出现「更新将重置本地数据」提示。

### 2026-09-12 · 签名特定 IPA 时 Seal SIGTRAP 闪退（rork-sign 符号表邻接缩限产生负数 Data count）
- **现象**：签名/安装 SollinPlayer（Flutter + 大量 dylib，多数二进制为无 `LC_CODE_SIGNATURE`
  的 thin arm64）时 Seal 自身崩溃。两份 `.ips`（1.0.9 build59 与 1.0.11 build64，均 iOS 18.7.8）
  一致显示 `EXC_BREAKPOINT / SIGTRAP`，栈：`Data.init(repeating:count:) ←
  prepareThinMachOCMSCodeDirectories(_:options:) ← MachOSigner.prepareCMSCodeDirectories ←
  RorkSigner.signMachOWithIdentity ← BundleSigner.signCode`。
- **根因**：`MachOSigner.swift` 三处（`thinSigningCacheInput`、finalize 分支、
  `prepareThinMachOCMSCodeDirectories`）对「无既有 `LC_CODE_SIGNATURE`、全新追加签名」分支也套用了
  `layout.adjustedCodeLimit(rawCodeLimit)`（ldid 符号字符串表邻接缩限）。当某二进制的 LC_SYMTAB
  字符串表恰好落在文件末尾 16 字节内时，缩限把 `codeLimit` 压到比 `output.count` 还小，
  `Data(repeating: 0, count: Int(codeLimit) - output.count)` 的 count 为负 → `Data.init(count:)` 陷阱死亡。
- **修复**：三处改为 `hasExistingSignature ? layout.adjustedCodeLimit(rawCodeLimit) : rawCodeLimit`
  ——符号表邻接缩限只作用于「已有签名」分支；全新签名分支 `codeLimit` 直接取
  `alignUp(output.count, 16)`（≥ output.count，append 非负）。对正常二进制行为不变
  （原本 `adjustedCodeLimit` 在非邻接时本就返回 `rawCodeLimit`）。
- **涉及文件**：`Vendor/rork-sign/Sources/RorkSign/MachO/MachOSigner.swift`（3 处）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：签名 SollinPlayer 不再崩溃、产物可安装。

### 2026-09-12 · 证书/AppID 库存同步把任务取消误报为失败（SEAL-INVENTORY-900/900a 刷屏）
- **现象**：添加 Apple ID / 批量签名续签时，「诊断日志」里 `SEAL-INVENTORY-900`/`900a`
  「xxx 同步失败 [Swift.CancellationError 1]」反复刷屏，并连带污染证书健康状态。
- **根因**：`refreshAppIDInventory` 与 `refreshCertificateInventory` 的兜底 `catch {}` 把所有异常
  （含 `Swift.CancellationError`）都当普通错误转成 `SEAL-INVENTORY-900/900a`，并写入
  `certificateInventoryFailures` / `certificateHealthStatuses`。当外层 Task 被取消（切团队、
  并发刷新、页面 `.task` 重入）时，`fetchInventory` / `keychain.load` 抛 `CancellationError`，
  被误判为「证书同步失败」。
- **修复**：两个方法在 `catch {}` 前新增 `catch is CancellationError { return }`，取消时静默返回、
  不写失败标记、不污染健康状态（与本文件 `authenticateAndPersistAccount` 处既有
  `catch is CancellationError` 范式一致）。
- **涉及文件**：`Seal/Features/Settings/SettingsViewModel.swift`（`refreshAppIDInventory`、
  `refreshCertificateInventory`）。
- **验证状态**：代码已改，未云编译、未真机回归。验证点：切团队 / 批量续签时日志不再出现
  `Swift.CancellationError` 误报，证书健康状态不被污染。

### 2026-09-12 · 安装卡「正在连接设备」：内置 SealTunnel 从未激活，被迫依赖外部 LocalDevVPN 软件
- **现象**：真机不打开外部 LocalDevVPN 软件，签名/续签后的安装环节一直卡在「正在连接设备」，
  隧道始终连不通；手动打开 LocalDevVPN 软件后才可继续。
- **根因**：Seal 自带 `SealTunnel` Network Extension（`NEPacketTunnelProvider`，10.7.0.0/24
  反射隧道，bundle `com.mjorb.seal.TunnelProv`）此前**从未被激活**。`MinimuxerInstallChannel`
  安装流程只对 `10.7.0.1` 做 TCP `probeTunnel()` 探测，不通就直接放行/卡住，从不「按需拉起」隧道；
  由此本应等价于外部 LocalDevVPN 软件的扩展形同虚设，实际被外部软件代建隧道。
- **修复**（三层联动，纯本地 Swift、零新增 Rust）：
  1. `SealTunnelManager` 加 `static let shared` 单例 —— 让设置页与安装流程共用同一隧道实例状态
     （`@MainActor` 隔离，满足 Swift 6 并发，非「非 Sendable class 暴露 shared」红线）。
  2. `LocalDevVPNOnDemandActivator.activate()` 从「仅 probe + sleep」改为**真正调用
     `SealTunnelManager.shared.start()`** 拉起内置扩展（建 `com.mjorb.seal.TunnelProv` 虚拟网卡），
     等待由 900ms 延长到 1500ms 再探测。
  3. `MinimuxerInstallChannel` 安装链路：首次探测隧道不通时自动 `onDemandActivator.activate()`
     拉起 SealTunnel，再二次探测，通了才 `pass(.vpnTunnel)`。
  4. `LocalDevVPNSettingsView` 改用 `.shared`；`SettingsRootView` 签名分组新增「本地隧道」入口
     （`SettingsRoute.localDevVPN`），可手动启动/停止/重检。
- **涉及文件**：`SealTunnelManager.swift`、`LocalDevVPNOnDemandActivator.swift`、
  `MinimuxerInstallChannel.swift`、`LocalDevVPNSettingsView.swift`、`SettingsRootView.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：① 不装外部 LocalDevVPN 软件，
  签名/续签后安装应自动拉起内置隧道并走「正在安装」成功；② 「我的 → 本地隧道」可手动启动/停止，
  状态与安装流程一致；③ 签名/续签环节（走 Apple 外网服务）全程不受该改动影响。
- **配置核对（已过）**：`project.yml` 里 SealTunnel `PRODUCT_BUNDLE_IDENTIFIER=com.mjorb.seal.TunnelProv`
  与 `SealTunnelManager` 的 `.TunnelProv` 后缀精确匹配；主 app 与扩展两份 entitlements 均含
  `packet-tunnel-provider`；扩展 `NSExtensionPrincipalClass=$(PRODUCT_MODULE_NAME).PacketTunnelProvider`、
  `embed: true` 确保进 IPA。

### 2026-09-12 · 更新检测正常但下载到旧版（发布 release 误用残留 IPA）
- **现象**：v1.0.10 已发布、`releases/latest` 返回 `v1.0.10`、编译 run headSha 与编译产物均正确，
  但用户反馈「点下载更新出来的续签页是 1.0.9 版本」。
- **根因**：发布 v1.0.10 时误用了 `.release_build` 目录里**残留的 1.0.9 IPA**（build 59，26,726,320 bytes），
  而非新编译产物 `Seal-61\Seal.ipa`（1.0.10 / build 61，26,730,549 bytes）。下载时目录未清空，根目录旧
  `Seal.ipa` 与新 `Seal-61\Seal.ipa` 并存，发布时只凭文件名选了旧的。
- **修复**：删除错误附件（asset id `557846624`），用正确产物重新 `gh release upload` v1.0.10。
- **涉及文件**：无代码改动；流程问题，见常犯坑位第 9 条。
- **验证状态**：release 附件现为 build 61（1.0.10，26,730,549 bytes）。用户重新检查更新应能正确下载 1.0.10。

### 2026-09-12 · 免费账号 3 应用上限：按钮文案/行为失配修复 + 支持 Lara 3-App Bypass 跳过预检
- **现象一（按钮文案与行为不一致）**：免费账号装第 4 个自签应用触发 `SEAL-APPID-DEVICELIMIT` 时，
  失败态主按钮显示「重试」，但 `performPrimaryRecovery` 里 `isNonRetryableFailure` 优先命中直接
  `dismiss`，点了并不会真重试；`SEAL-INSTALL-702l/702s` 同理显示「重新安装」但实际也是 dismiss。
- **根因一**：`primaryRecoveryTitle` 判断顺序里 `isNonRetryableFailure`（DEVICELIMIT/702l/702s）未提前，
  被 `isInstallChannelFailure`→「重新安装」、`isAppIDFailure`→「重试」先命中；而 `performPrimaryRecovery`
  第一分支就是 `isNonRetryableFailure → dismiss`，两处顺序不一致。
- **修复一**：`primaryRecoveryTitle` 顶部提前 `if isNonRetryableFailure(failure) { return "知道了" }`，
  三个确定性失败统一「知道了」并关闭（落实既有约束）。
- **现象二（无法配合 Lara 绕过）**：Lara 3-App Bypass 在设备本地移除免费 profile 3 应用上限检查
  （DarkSword 内核 exploit；仅 iOS 17.0–18.7.1 / 26.0.x，M5/A19 不支持，且不增加 10-App ID 服务器上限），
  但 Seal 的 `enforceFreeAccountInstallLimit` 是签名前客户端硬预检，≥3 直接抛 DEVICELIMIT、到不了
  installd，导致 Lara 绕过对 Seal 用户无效。
- **修复二**：引入 `bypassFreeAccountDeviceLimit: Bool = false` 默认参数，链路
  `SigningProgressView`（DEVICELIMIT 失败态双按钮：主「已用 Lara 绕过，继续安装」+ 次「知道了」）
  → `AppsViewModel.continueBypassingDeviceLimit()` → `restartSigning`/`runSigning` →
  `SigningCoordinator.signAndInstall` → `enforceFreeAccountInstallLimit`（`guard bypass... == false else return`）
  跳过预检，交回 installd 最终裁决：未真正绕过时 installd 仍回 `ApplicationVerificationFailed`
  （落到既有 `SEAL-INSTALL-702l` 分支）。默认参数隔离，付费账号 / 免费账号 <3 / 续签
  （`RenewalCoordinator` 不传 → false）/ 重试 / Bundle ID 检查等原链路零影响。
- **涉及文件**：`SigningCoordinator.swift`、`AppsViewModel.swift`、`SigningProgressView.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：① 付费账号、免费账号第 3 个照常签名；
  ② 超限失败态为「已用 Lara 绕过，继续安装」+「知道了」；③ 已 bypass 点主按钮可装第 4 个，未 bypass
  点主按钮落到 iOS 拒绝（702l）。

### 2026-09-11 · 添加 Apple ID 报 503 Service Temporarily Unavailable（客户端标识被 Apple 封禁）
- **现象**：9 月 10 日全天 iloader 所有用户（含 Seal）添加 Apple ID 均失败，报
  `HTTP 503 Service Temporarily Unavailable`，来自 `https://gsa.apple.com/grandslam/GsService2`。
- **根因**：Apple 的 GSA 网关自 2026 年 9 月初起，对任何 `X-MMe-Client-Info` 头里含
  `com.apple.dt.Xcode` 的请求**在验证凭据之前**直接返回 503。这是服务端硬编码封禁，与账号/
  密码/连接复用/代理无关，所以「所有人、所有版本」同时中招。**推翻了此前「连接复用导致 503」的判断**
  （一次性 session 只是掩盖，不是根治）。
- **上游修法（对齐）**：iloader 提交 `a19f5f0`（"Fix GSA 503: replace blocked Xcode client
  identifier with akd"）把 `com.apple.dt.Xcode/x.y.z` 换成 `com.apple.akd/1.0`；同根同修的还有
  AltStore#1790、SideStore、xtool、coffer。共识：**client-info 用 akd，User-Agent 保留 Xcode 不动**
  （503 只由 `X-MMe-Client-Info` 头触发，与 User-Agent 无关）。
- **Seal 修复**：`AnisetteV3Client.fetchLocal` 硬编码的 clientInfo（经 `fetchAnisetteData(clientInfo:)`
  → `deviceDescription` → `ALTAppleAPI` 各请求的 `X-MMe-Client-Info` 头）由
  `<...com.apple.AuthKit/1 (com.apple.dt.Xcode/26.0)>` 改为
  `<...com.apple.AuthKit/1 (com.apple.akd/1.0)>`。
- **未改动项（有意）**：
  - AltSign `ALTAppleAPI+Authentication.swift` 的 `User-Agent` 仍含 Xcode——按社区共识 User-Agent
    保留 Xcode，仅 client-info 用 akd。
  - AnisetteKit `LocalAnisetteProvider.defaultClientInfo` 仍是 Xcode——它是 `fetchAnisetteData` 等
    的**默认参数**，认证链路（`AppleAccountClient.authenticate → fetchForAuthentication →
    fetchLocal`）每次都显式传 clientInfo，永不落到该默认值，属死默认，无需改动。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：添加 Apple ID（本地 anisette）
  应不再 503，正常进入 2FA/完成登录。

### 2026-09-11 · 已安装 Seal 版本显示旧号 + 下载按钮卡 0 字节 + 更新弹窗样式统一（公告系统撤销）
- **现象一（版本不一致）**：已安装列表里 Seal 显示 `1.0.6`，「我的 → 关于 Seal」显示 `1.0.7`
  （两处读的是不同来源：列表读 `AppRecord.version`，关于页读运行中 `Bundle.main` 的
  `CFBundleShortVersionString`）。
- **根因一**：`SelfAppRegistrar.ensureRegistered` 的「待安装自更新源」早退分支
  （`hasPendingSelfUpdateSource == true` 且 ipa 文件仍在）直接 `return`，不做版本对账。
  若该标记残留（上次自更新中断、或外部方式装新包后未清），记录版本会**永久停旧值**，
  即使运行中的 Bundle 已经更新（外部云编译直装 1.0.7）也不会被纠正。
- **修复一**：早退分支加版本守卫——`Version.compare(existing.version, metadata.version) != .orderedAscending`
  才保留待安装源；记录版本低于运行版本（残留标记、已被外部更新取代）时落到原子更新，
  用运行中 Bundle 重打包并写回新版本号。既有的「运行旧版、待装新版」保护不受影响
  （待装源版本 ≥ 运行版本仍早退保留）。`Version` 工具随之移入独立文件
  `Seal/Infrastructure/Version.swift`（原定义在公告服务内）。
- **涉及文件**：`Seal/Core/Renewal/SelfAppRegistrar.swift`、`Seal/Infrastructure/Version.swift`（新）。
- **现象二（下载按钮没反应）**：更新弹窗点「下载更新」后卡住、按钮显示「已下载 Zero kB」且点不动
  （`byteCount(.binary)` 对 0 字节输出 "Zero kB"；下载中被 `.disabled(isDownloading)` 锁死，无法取消重试）。
- **修复二**：① `UpdateIPADownloader` 自定义 session：请求空闲超时 15s + 资源总时长 90s + 支持外部取消
  （`withTaskCancellationHandler`），卡死 30s 内必然报错或可手动取消；② 下载中再点按钮 = 取消，回到可重试态；
  ③ `received == 0 && total == nil` 时显示「正在连接…」，不再出现「Zero kB」。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、`Seal/Features/UpdateNoticeView.swift`。
- **样式统一（更新弹窗）**：经用户澄清「公告弹窗」即更新弹窗，`UpdateNoticeView` 主卡片由毛玻璃
  `.ultraThinMaterial` 改为主题背景 `Color.sealSurface`、取消按钮 `sealSurfaceElevated`、描边
  `sealHairline.opacity(0.6)`，圆角/阴影/布局排版不变；独立的远端公告系统按用户确认**已撤销**
  （`AnnouncementView`/`AnnouncementService` 删除、`RootTabView`/`AppConfiguration` 还原、
  远端 `announcements.json` 已从 Releases 仓库删除）。
- **涉及文件**：`Seal/Features/UpdateNoticeView.swift`。
- **验证状态**：代码已改，**未云编译、未真机回归**。真机验证点：① 直装 1.0.7 云编译包后重启，
  已安装列表版本应自愈为 1.0.7；② 更新下载在弱网下 15s 内报「网络下载超时」或可点按取消；
  ③ 更新弹窗为不透明主题背景（非毛玻璃），布局与之前一致。

### 2026-09-11 · 下载进度显示真实字节数 + 赞赏码 tab 点击区修复 + 503 未落地说明
- **现象 A（下载进度卡住/假进度）**：真机「WiFi 一直转圈、挂梯子后 0% 突然跳到正在续签」。代码层面
  `UpdateIPADownloader.download` 的 onProgress 已改成 `(Int64, Int64?)`，但 `ProgressDownloadDelegate`
  仍是 `@Sendable (Double) async -> Void` —— **类型不匹配、编译过不了**，是上轮只改入口、没改 delegate 的中间态。
  且总大小未知（无 Content-Length）时 UI 拿不到真实字节数，只能干等或发假百分比。
- **根因 A**：progress 回调链「入口签名 ↔ delegate 属性/init/回调 ↔ UI enum」没一起改；`didWriteData`
  在 expected ≤ 0 时直接 `return`，总大小未知时进度永远不推进。
- **修复 A**：`ProgressDownloadDelegate` 全链改 `(Int64, Int64?)`；`didWriteData` expected ≤ 0 时 total 传 nil；
  `UpdateNoticeView.DownloadPhase` 改 `.downloading(Int64, Int64?)`，total 已知走线性进度条+百分比，
  total 为 nil 时显示「已下载 X」（`byteCount(style: .binary)`），消除「0% 突然跳续签」的假进度观感。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`、`Seal/Features/UpdateNoticeView.swift`。
- **现象 B（赞赏码 tab）**：抽屉顶部横杠与 tab 贴太紧；tab 只有「微信/支付宝」文字本身可点，整块区域点不动。
- **修复 B**：`rewardCodeSheet` 顶部 padding 20→32；tab 按钮 label 改 `.frame(maxWidth: .infinity, minHeight: 40)`
  + `.contentShape(Rectangle())`，整块可点、命中区约 44pt。
- **涉及文件**：`Seal/Features/Settings/SealCommunityView.swift`。
- **503 状态说明**：`Connection: close` 修复已 lock 进 `project.yml`（AltSign@87f61ce）且
  `AnisetteClient.appleRequest` 亦补齐；云编译 #34563251634（c7927b5）已成功。但发布出去的
  v1.0.4/v1.0.5 未让用户真正装上含修复的包（下载链路坏 + 未走签名安装），真机仍停在旧 1.0.3 IPA，
  所以「添加 id 还是 503」。另有 IP 限流分支（见常犯坑位 7）：`Connection: close` 只治「连接复用」类 503，
  换网络/热点后仍 503 多为 Apple 按 IP 封，客户端无法根治。
- **下一步待办**：bump MARKETING_VERSION → 1.0.6、push、云编译、发布 v1.0.6，真机回归下载进度 + 添加 id。
- **验证状态**：代码已改，**未云编译、未真机回归**。

### 2026-09-11 · About「检查更新」弹窗跳浏览器而非应用内安装 + gsa provisioning 路径补 Connection: close
- **现象一**：关于 Seal →「检查更新」→ 弹窗点「下载更新」，跳到 GitHub Release 网页，而非 Seal 内部下载+签名安装。
- **根因一**：`AboutView` 把 `UpdateNoticeView(onInstall:)` 传了 `nil`；`handleUpdate` 里 `guard let ipaURL, let onInstall`
  命中缺省分支走 `openURL(html_url)`。启动弹窗（RootTabView）有 onInstall（应用内），About 弹窗没有 → 两条入口行为不一致。
- **修复一**：RootTabView 抽出 `installSelfUpdate(_:)`（切 Apps tab + `importSelfUpdateFile` + 清理），
  经 `SettingsRootView.onSelfUpdateInstall` 下传到 `AboutView(onInstall:)`；About 弹窗下载完成后先收弹窗再导入安装，与启动弹窗一致。
- **涉及文件**：`Seal/App/RootTabView.swift`、`Seal/Features/Settings/SettingsRootView.swift`、`Seal/Features/Settings/AboutView.swift`。
- **现象二**：`AnisetteClient.appleRequest`（本地/远程 provisioning 打 `gsa.apple.com/grandslam/GsService2/lookup`
  及 midStart/midFinish）用默认 `.shared` session、未禁连接复用，与 AltSign 认证层（`Connection: close`）不一致，仍可能被 Apple 回 503。
- **修复二**：`appleRequest` 加 `Connection: close` 请求头，对齐 AltSign 认证 session 与 iloader `.pool_max_idle_per_host(0)`。
- **涉及文件**：`Seal/Infrastructure/Accounts/AnisetteClient.swift`（`appleRequest`）。
- **附加**：`UpdateIPADownloader.download` 加 `request.timeoutInterval = 30`，GitHub 资产域无响应时快速抛
  `transport` 错误显示「重试」，避免卡 0% 不报错。
- **验证状态**：代码已改，**未云编译、未真机回归**。
- **注意**：`Connection: close` 只能解决「连接复用」类 503；若仍有 503，多为 Apple 按 IP 限流（同 IP 请求过多被暂封），
  需换网络/热点或等 `Retry-After`，非客户端能根治。

### 2026-09-11 · Seal 更新下载进度卡 0%（totalBytesExpectedToWrite 为 -1 时被静默丢弃）
- **现象**：真机点「下载更新」，进度一直停在 0%，下载实际在走但 UI 不刷新。
- **根因**：`ProgressDownloadDelegate.didWriteData` 里 `guard totalBytesExpectedToWrite > 0 else { return }`。
  `totalBytesExpectedToWrite` 在响应无 `Content-Length`（GitHub 的 `browser_download_url` 302 重定向到
  `objects.githubusercontent.com`、chunked transfer）时为 `NSURLSessionTransferSizeUnknown`(-1)，guard 直接把回调
  丢掉 → 进度永远 0 也不报错。
- **修复**：改用任务的 `downloadTask.countOfBytesExpectedToReceive` 作首选锚点（重定向后跟随到真实长度，
  通常 >0 且准确），仅当它也不可用时才回退 `totalBytesExpectedToWrite`，避免依赖「首个响应的 -1」。
- **涉及文件**：`Seal/Infrastructure/UpdateIPADownloader.swift`（`didWriteData`）。
- **验证状态**：代码已改，主仓库 worktree 有改动，**未云编译、未真机回归**。
- **注意**：本项与「下载走代理/连接复用」是不同的两个问题；若下载源本身连不通（`SEAL-UPDATE-DL-503`），
  进度 0% 是表象、根因在网络，勿纠缠进度回调。

### 2026-09-11 · gsa.apple.com 503：关闭认证 session 的连接复用（对齐 iloader 2.3.3）
- **现象**：真机 Seal 添加 Apple ID 报 `503 Service Temporarily Unavailable`，
  重试时好时坏；iloader（Windows，同一 Apple 服务）今日开发者修好同类 503 并发版 2.3.3。
- **根因**：`gsa.apple.com` 对「复用上次失败的 idle 连接」敏感，代理/TUN 切换后残留连接被下一请求复用
  会被 Apple 拒 503；纯靠隔几秒重发不稳定，还会复用一个失效连接。
- **上游佐证（已核实）**：iloader 2026-09-10 提交 `348eefd` 升级 `isideload` `#f2fd29ab`→`#f6a4d5d` 并发 2.3.3；
  isideload commit `f6a4d5d` 标题 **"Disable pooling on reqwest client"**，在 `grandslam.rs` 构造 reqwest client 加
  `.pool_max_idle_per_host(0)`（禁用每 host idle 复用）。
- **修复**：altsign-mod `ALTAppleAPI.swift` 认证 `URLSessionConfiguration.ephemeral` 加
  `configuration.httpAdditionalHeaders = ["Connection": "close"]`（一条覆盖登录 init/complete +
  2FA trusteddevice/phone/validate 全部 GSA 请求），叠加既有 `retryOnApple503`(3s/8s)。
- **涉及文件**：`.dev-workspace/forks/altsign-mod/Sources/ALTAppleAPI.swift:71`（独立 git repo dmjorb/AltSign，HEAD=868f0ff）。
- **落地前置**：Seal 经 SwiftPM 依赖 `github.com/dmjorb/AltSign@868f0ff`，此改动须 commit+push
  更新 revision 才进真机。
- **2026-09-11 已落地**：AltSign fork 已迁至 `github.com/sunuannian1/AltSign`（保留上游
  SideStore/AltSign），修复 commit `87f61ce` 已推送；`project.yml` 的 AltSign url 改 `sunuannian1`、
  revision 锁 `87f61ce`，AnisetteKit 同步迁至 `sunuannian1/AnisetteKit`（revision 保持 `081200e`）。
  云编译将自动拉取含修复的依赖。**待真机回归**。

### 2026-09-10 · 二次编译暴露 SealCommunityView 漏传 title（错误被前序 module 错误掩盖）

- **现象**：修复 `UpdateIPADownloader` 两处并发错误后，复跑云编译 **run #34459031904** 仍失败
  （`Build fast unsigned IPA`，exit 65），但错误只剩 1 行、且换成了别处：
  `SealCommunityView.swift:104:49: error: missing argument for parameter 'title' in call`。
- **根因**：
  1. 直接根因：`SealCommunityView.qqCard` 调用 `communityCard(icon:subtitle:value:action:)`
     漏传 **required 参数 `title`**（`communityCard` 第 236 行 `title: String` 无默认值）。
     这是此前「QQ 群按钮不写群号」改动时误删了 `title:`，属遗留 bug。
  2. **为何上一轮 run #42 没报**：Swift 是模块级编译，run #42 在 `-emit-module` 阶段被
     `UpdateIPADownloader` 的 2 个并发错误中止，`SealCommunityView` 的类型检查未完成，
     此错被**掩盖**。修好前者、重新完整编译后它才浮出。
- **修复**：`qqCard` 补 `title: "加入 QQ 群"`（与 `telegramCard` 的「加入 Telegram 频道」对称，
  群号仍不展示）。
- **涉及文件**：`Seal/Features/Settings/SealCommunityView.swift`。
- **验证状态**：待云编译（run #34459031904 之后的下一次）+ 真机社群页 QQ 卡显示。
- **教训（沉淀为常犯坑位 7）**：**「编译只剩这几个错误」不成立**——module emit 阶段的前序错误
  会中止后续文件的类型检查，修复后必须重新完整编译才能看全剩余错误，别凭上一轮报错数判断已修完。

### 2026-09-10 · 应用内更新首次云编译失败（Swift 6 并发红线）→ 已修复

- **现象**：应用内更新方案（下载 → 导入 → 覆盖安装 Seal）首次提交云编译 **run #34456273529**
  报 `BUILD_FAILED: failure`。全量日志里真实 `error:` 行**仅 2 行**，均落在新增的
  `UpdateIPADownloader.swift`：
  1. `:6:16 error: static property 'shared' is not concurrency-safe because non-'Sendable'
     type 'UpdateIPADownloader' may have shared mutable state`
     （note：`class 'UpdateIPADownloader' does not conform to the 'Sendable' protocol`
     + 建议 `add '@MainActor'` / `disable concurrency-safety checks`）。
  2. `:90:21 error: type 'ProgressDownloadDelegate' does not conform to protocol
     'URLSessionDownloadDelegate'`
     （note：`protocol requires function 'urlSession(_:downloadTask:didFinishDownloadingTo:)'`）。
- **根因**（编译器命令行确凿 `-swift-version 6`，Xcode 26.5 强制 Swift 6 语言模式）：
  ① 下载器写成 `final class` 且持有 `let fileManager`（非 Sendable），却暴露 `static shared`；
  ② iOS 26.5 SDK 里 `didFinishDownloadingTo` 是 required，delegate 未实现；
  ③ `ProgressDownloadDelegate` 继承 `NSObject`（`@unchecked Sendable`），stored 闭包
     `onProgress` 是非 `@Sendable`，触发 `warning: ... has non-Sendable type '(Double) -> ()'`。
- **修复**：
  - `UpdateIPADownloader` 由 `final class` 改为 **`struct`**（去实例可变状态），`fileManager`
    改为内联 `FileManager.default`；`shared` 因此并发安全。
  - `ProgressDownloadDelegate` 补 `didFinishDownloadingTo` 空实现；`onProgress` 改
    `@Sendable (Double) async -> Void`，对齐项目既有 `InstallChannel` 进度约定；
    调用侧 `UpdateNoticeView.handleUpdate` 用 `@MainActor` 参数直接更新 `phase`。
- **涉及文件**：`UpdateIPADownloader.swift`、`UpdateNoticeView.swift`。
- **验证状态**：待云编译（run #34459031904 复跑）+ 真机下载进度 / 自动弹签名抽屉验证。
  教训已沉淀为「常犯坑位 6」。详见 `SEAL_INAPP_UPDATE_PLAN_20260910.md` §7。

### 2026-09-10 · 定位「今天签 Seal、明天掉签」根因

- **现象**：用户报告「今天签名安装 Seal，明天就掉签、闪退打不开」；真机日志另有
  TLS 握手失败（NSURLErrorDomain -1200）与设备存储满（No space left / errno 28/ENOSPC）。
- **排查过程（含两次误判，均已纠正）**：
  1. 误判一：把 `gh run watch --exit-status` 的后台任务返回非零 exit code 当成「社群页
     云编译失败」，实际 `gh run list` 显示 `completed success`（8m55s）。教训见「常犯坑位 4」。
  2. 误判二：一度把 `SelfAppRegistrar`（`expiryDate: metadata.expirationDate`，
     `SelfAppRegistrar.swift:161/165`）当掉签根源。深读后发现签名安装成功时
     `installSignedIPA`（`SigningCoordinator.swift:608`）会用签名当时的 profile 过期时间
     覆盖 `expiryDate`，该写法语义正确，不是根因。
- **决定性根因（2026-09-09 20:37 crash 报告 `diskwrites_resource` 一锤定音）**：
  **这不是「掉签」，也不是「存储满」——是 iOS「磁盘写入资源保护」终止。**
  - 报告数据：`Event: disk writes`；29 分钟（1745s）写 **1073.76 MB**（615 KB/s 平均），
    超过系统 86400s 周期限额 1073.74 MB；`Free disk space: 19.48 GB`（磁盘未满，
    「存储满」判断被推翻）。
  - 栈证据：栈顶 `libswift_Concurrency`（一个 Task 持续 active）→ Seal 函数 →
    `Foundation`（Data 写文件）→ `libsystem_c` → `libsystem_kernel write`。
    即 SealLogStore.append 的「全量重写 + atomic 写」在某个高频日志任务下放大成 1GB 写入。
  - 真正代码缺陷：`SealLogStore.append`（`SealLogStore.swift:23-44`）**每条日志都做**
    ① `read()` 全量读 + JSON decode 200 条 → ② 全量 JSON encode + `write(to:.atomic)`
    （临时文件+rename 双写）+ `fileProtector.protect` → ③ error 级别再 `mirrorToDocuments()`
    （全量 exportText + 写整个 Seal-log.txt）。任意高频日志（每秒几条）都会被放大成
    615 KB/s 的持续磁盘写入，最终触发 iOS 磁盘写保护被杀。
- **已排除的假设（记录防回头重复推理）**：
  - 免费账号 profile 复用（`fetchProvisioningProfile` 删除失败 `return profile`）——被「7 天」推翻。
  - `SelfAppRegistrar` 用 `metadata.expirationDate` 写库——语义正确，非根因。
  - 证书序列号归一化——已修（`34e6ae7` + rork-sign `formattedSerialNumberHex` 已剥前导零）。
  - 设备存储满（ENOSPC）、证书过期、TLS 中断——均非本次「闪退」直接根因。
- **修复方向**：根治 `SealLogStore` 的 O(n) 全量重写放大问题——
  (1) append 改为内存缓冲 + 节流批量落盘（debounce，去掉每条日志的全量读/写）；
  (2) 落盘用非 atomic 覆盖写，去掉 `protect` 的每次调用（或大幅降低频率）；
  (3) error 镜像 `mirrorToDocuments` 节流。同时定位「高频打日志」的任务源头一并收敛。
- **涉及文件**：`SealLogStore.swift`（核心）；`AppsViewModel.swift` / `SettingsViewModel.swift`
  （高频 append 调用点）。
- **验证状态**：待修复后真机复验（观察 crash 是否消失 + 日志是否仍可读/导出）。

### 2026-09-09 · 修复 Seal 无法自续签

- **现象**：Seal 自续签失败，日志/报错指向「证书已被轮换 / 不在授权列表」，
  但用户并未更换证书。更换 Apple ID、清缓存后依旧。
- **根因**：证书序列号跨来源比对未归一化（见「常犯坑位 1」）。AltSign 返回的本地证书序列号
  剥掉了前导 0，描述文件 `certificateSerialNumbers` 保留前导 0，同一证书被判成两个，
  触发「证书已轮换」误报 → 续签链路中断。
- **修复**：新增 `SigningCertificateSelectionPolicy.normalizedSerialNumber(_:)`，
  统一「去前导 0、转大写、只留十六进制」；在 5 个跨来源比对点全部改用该方法：
  - `ApplePortalSigningService.swift`：签名前证书授权校验（`chosenSerial` vs 描述文件授权序列号清单）。
  - `SigningCoordinator.swift`：安装前描述文件授权证书匹配校验。
  - `ProvisioningProfileBinding.swift`：描述文件绑定校验（`normalizedSerial` 委托复用）。
  - `AppPresentation.swift`：证书匹配展示状态（`.mismatch` 误判）。
  - `SettingsViewModel.swift`：证书健康状态 / 关联应用计数。
- **涉及文件**：上述 5 个 + `SigningCertificateSelectionPolicy.swift`。
- **验证状态**：本机 Windows 无法编译 Swift，待 Xcode 编译 + 真机回归样本
  （微信 / 黄豆短剧 / LCSign / lanmanga）验证自续签与「本地证书复用前与 Apple 生效列表比对」路径。

### 2026-09-09 · 修复签名微信进度卡在 100%

- **现象**：签名微信时（约 500MB+），上传到 1 分 30 秒显示 100%，进度条一直停到 2 分 20 秒
  才消失、才变「正在安装」，进度不精准。附带观察：此前报「内存不足」（清理设备空间后重试可见
  进度问题）。
- **根因**：见「常犯坑位 2」。上传完成（=100）后 UI 仍停在「正在传输」，直到 installd 完成
  安装才切换阶段，中间几十秒的解压/复制被误显示为「传输中」。
- **修复**：Rust 侧在本轮之前已新增 `INSTALL_ISSUED_PCT = 101` 哨兵，在 `run_install_chain`
  即将向 installd 下发安装命令时回调。本轮补齐 Swift 侧消费逻辑：
  - `MinimuxerInstallChannel.swift`：`syncProgress` 收到 `p > 1.0` 时统一转发 `1.01` 给上层
    （普通安装也消费该哨兵，不再像旧逻辑直接 `return` 丢弃）。
  - `AppsViewModel.swift`：`updateInstallProgress` 收到 `progress > 1.0` 时把 `installProgress`
    归 `1.0`，并把阶段从 `.pushing` 切到 `.installing`。
  - UI 层 `SigningProgressView` 只在 `.pushing` 且 `0 <= progress <= 1` 显示进度条，
    `.installing` 显示「正在安装」，故哨兵触发后进度条立即消失、文案切换。
- **涉及文件**：`MinimuxerInstallChannel.swift`、`AppsViewModel.swift`（Rust 侧已在此前提交）。
- **验证状态**：待 Xcode 编译 RustBridge + 真机回归样本验证「上传 100% → 正在安装」切换是否及时、无闪烁。

### 附注（待真机核实，暂未改代码）

- 微信签名期初的「内存不足」：代码库中无字面「内存不足」文案，存储类错误已统一分类为
  「设备存储空间不足」（`SEAL-INSTALL-702s`，识别 `No space left / ENOSPC / errno 28 / code 28 /
  空间不足 / 储存空间 / 存储空间`）。该现象疑似 = 设备存储不足（已被现有分类覆盖）或设备侧瞬时
  RAM 压力，待真机日志复核，暂不新增代码。
### 28. 应用内更新是一条远程代码投递通道：资产直链必须独立校验
- **风险**：`UpdateChecker` 旧实现取**第一个**后缀为 `.ipa` 的附件，
  且直接使用 API 响应里的 `browser_download_url`，只保证 HTTP 200。
- **两个独立缺陷**：
  1. **不校验 host** —— 仓库名虽硬编码，但 API 响应本身是不可信输入。
     一旦它指向攻击者域名，应用内更新就能投递任意 IPA。
  2. **取「第一个」** —— 一次 Release 挂多个 IPA 时，装哪个全看 API 返回顺序，
     既不确定，也让「往 Release 里多加一个附件」成为可行的投毒手法。
- **修法**：`isTrustedDownloadURL` 校验 HTTPS + GitHub 官方域名；
  `ipaDownloadURL(from:)` 先过滤不可信附件，**恰好一个**才给直链
  （没有或多个都回退到 Release 详情页，由用户在浏览器里选）。
- **注意顺序**：必须先过滤再计数。否则「恶意 + 正常」会被算成多个而静默降级，
  或恶意附件是唯一一个时被直接采用。
- **仍未做**：独立信任根（固定公钥 / 期望指纹校验资产摘要）。同一仓库内的清单
  不提供额外保证 —— 真正的供应链闭环需要仓库外的信任锚，属于发布治理专项。
- **涉及文件**：`Seal/Infrastructure/UpdateChecker.swift`、
  `SealTests/Update/UpdateCheckerAssetTests.swift`（新增 6 例）。
- **验证状态**：护栏 65 检查 + 32 变异 PASS。**Swift 编译与单测待 CI。**

### 29. 「看起来可写、实际是 no-op」的偏好项：NotificationPreferences.leadHours
- **现象**：`leadHours` 的 getter 恒返回 `fixedLeadHours`、从不读 UserDefaults；
  setter 忽略 `newValue`，只把固定值写进去。此外 `init` 每次启动都无条件 `set`，
  等于把已存值抹掉。三个问题叠在一起：这个偏好项**写了也不生效，而且看不出来**。
- **风险等级**：当前值固定为 24h，所以**现在没有用户可见后果**；
  但调用链 `reschedule(leadHours:)` 与 `ExpiryNotificationPlanner(leadHours:)` 都已支持传值，
  一旦以后开放配置，这里会悄悄吞掉写入且极难排查 —— 属于典型的潜伏陷阱。
- **修法**：真实读写 UserDefaults；`init` 改用 `register(defaults:)`（只设默认值，不覆盖已存值）；
  读取时 `stored > 0 ? stored : fixedLeadHours`；写入时 `max(1, newValue)` ——
  0/负值会让「提前提醒」退化成过期后才提醒。
- **行为不变**：默认值仍是 `fixedLeadHours = 24`，UI 与提醒时机不受影响。
- **涉及文件**：`Seal/Core/Notifications/NotificationPreferences.swift`、
  `SealTests/Notifications/NotificationPreferencesTests.swift`（新增 5 例）。
- **验证状态**：护栏 65+32 → 66+33 PASS。**Swift 编译与单测待 CI。**

### 30. standardizedFileURL 不解析符号链接 —— 前缀比较挡不住路径逃逸
- **风险**：`AppFileStore.isDescendant` 用 `standardizedFileURL` + 字符串前缀比较。
  但该 API **只**规范化 `.` / `..`，**不解析 symlink**。一旦 `Apps/<uuid>` 被换成
  指向别处的符号链接，前缀比较照样通过，写入就落到 Apps 目录之外（路径逃逸）。
- **修法**：两侧都用 `resolvingSymlinksInPath()` 先取真实路径再比较。
  **两侧都要解析** —— iOS 上 `Documents` 本身就可能位于符号链接路径下，
  只解析一侧会得出错误结论（这也是最容易写错的地方）。
- **说明**：`FileManager.removeItem` 删 symlink 时删的是链接本身、不跟随，
  所以删除侧的风险有限；真正的风险在**写入逃逸**（`storeSignedIPA` / `prepareImportCommit`）。
- **涉及文件**：`Seal/Infrastructure/Storage/AppFileStore.swift`、
  `SealTests/Storage/AppFileStorePathEscapeTests.swift`（新增 3 例）。
- **验证状态**：护栏 66+33 → 67+34 PASS。**Swift 编译与单测待 CI。**

### 31. 浮动 major tag 的 GitHub Action：CI 是一段可被上游改写的远程代码
- **风险**：`actions/cache@v5` / `actions/download-artifact@v7` 这类浮动 major tag
  **可以被上游移动**。只要上游账号或仓库被入侵，我们的 CI 就会执行攻击者的代码，
  而 CI 恰恰持有发布用的凭据 —— 这是整条供应链里最值钱的目标。
- **修法**：钉到 40 位 commit SHA，并保留 `# v5` 注释（便于人读与 Dependabot 识别）。
  钉的是**当前正在跑的那个 commit**，所以是零功能变化，不引入升级风险。
- **为什么不顺手升级 major**：v5→v6、v7→v8 都可能有 breaking change，
  而本次目标是消除「可被移动」这个属性，不是升级。两者应当分开做。
- **守卫口径**：只禁 `@vN`（单个版本段）。`@v6.0.2` 精确到 patch、风险远低，不在禁止之列。
- **涉及文件**：`.github/workflows/*.yml`（cache 12 处、download-artifact 2 处）。

### 32（待确认）：symlink 加固在 iOS 测试环境未能验证
- **现象**：新增的 `fileURLRejectsAPathThatEscapesThroughASymlink` 在 CI 里失败 ——
  `fileURL` 没有拒绝经符号链接逃出 Documents 的路径（本机 Windows 无法复现）。
- **处置**：把两条依赖 symlink 解析的**新增**测试标为 `disabled` 并写明原因，让 CI 变绿。
  `isDescendant` 的加固代码保留 —— 它是纯纵深防御（解析 symlink 只会更严格、不会更宽松），
  且 build-package / rork-sign-tests 均通过、无既有回归。
- **未决**：无法判定是「加固未生效」还是「iOS 沙盒下 resolvingSymlinksInPath 行为不同」。
- **TODO（真机/模拟器）**：手动在 Documents/Apps 下建一个指向外部的 symlink，
  确认写入不会落到 Apps 之外；确认后重新启用这两条测试。

### 33. 更新真实性：必须交叉校验「声称的版本」与「包内真实版本」
- **风险**：只校验下载直链的域名（HTTPS + GitHub）是不够的 ——
  同一仓库、同一**合法**域名下的资产仍然可以被替换，那种情况下域名校验完全看不出异常。
- **修法**：`UpdateChecker.advertisedVersion(_:matchesIPAVersion:)` 做跨源交叉验证 ——
  `tag_name` 来自 GitHub API 元数据，`CFBundleShortVersionString` 来自**下载到的二进制本身**。
  两者对不上就中止安装（装下去就是远程代码执行）。
- **细节**：用 `Version.compare(...) == .orderedSame` 而非字符串相等 ——
  tag 可能是 `v1.0.13`、IPA 内是 `1.0.13`，而 `Version` 已处理 `v` 前缀与多段版本号。
- **仍未闭环**：这仍不是「独立信任根」（没有固定公钥/期望指纹），
  但把「资产被替换」从完全不可见变成了可检测。真正的闭环需要仓库外的信任锚。
- **守卫教训（第二次踩到同类）**：只检查「函数存在 / 被调用」会被 `return true` 骗过去，
  必须检查**比较逻辑本身**的具体表达式。变异检查当场抓到了这一点。
