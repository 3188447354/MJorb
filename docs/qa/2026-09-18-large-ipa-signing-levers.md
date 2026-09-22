# 大体积 IPA 签署慢：三个候选杠杆的现状与「为什么先不动」

- 日期：2026-09-18
- 结论一句话：**代码层还没有任何提速改动**，只有耗时埋点（构建 130 起）。
  **在拿到真机分段耗时之前不动引擎** —— 三个候选杠杆的代价差别很大，选错就是白烧一轮。

## 用户的问题

「快速签署大体积 IPA 包的问题修复了吗」—— 到本文为止，**没有**。

已进远端的是**取证**，不是优化。`Seal/Infrastructure/Signing/ApplePortalSigningService.swift`：

| 日志文案 | 行 | 说明 |
| --- | --- | --- |
| `签名：设备环境已就绪，耗时 N 秒` | 602 | anisette / 设备环境 |
| `签名：应用文件准备完成（解压 + 结构改写；重签与打包另计），耗时 N 秒` | 697 | prepare 阶段 |
| `签名：打包完成（deflate），耗时 N 秒` | 788 | 注释自称「很可能是本地耗时的大头」 |
| `签名：重签完成（逐 Mach-O 串行），耗时 N 秒` | 2429 | 引擎重签 |

⇒ **装构建 130（或 131）签一个大包，这四行就能把时间切开。** 这是下一步的全部前提。

## 杠杆 ①：引擎逐 Mach-O **串行**

**事实**：`Vendor/rork-sign/Sources/RorkSign/` 全目录 **零并发原语** ——
`withThrowingTaskGroup` / `TaskGroup` / `DispatchQueue.concurrentPerform` / `Task.detached`
**一个都没有**（grep 为空）。日志文案自己就写着「逐 Mach-O **串行**」。

**为什么先不动**：这是**vendored 引擎**，并发化要逐处论证线程安全（签名写回是
in-place、`context.signedCode` 是可变累积、`BundleSigningContext` 是 `inout`）。
而且「串行是不是瓶颈」完全由上面那行 `重签完成…耗时` 回答 —— 现在动手就是**先调参后取证**。

## 杠杆 ②：签名缓存 —— 是**真缺口**，但**不是这个问题的解**

**事实（这是真缺口）**：引擎有完整的公开 API `SigningCacheOptions`
（`Bundle/BundleSignatureCache.swift:15`），而 **`Seal/` 下 `signingCache` 出现 0 次** ——
`Seal/Infrastructure/Signing/RorkAppSigner.swift:104-113` 构造 `AppSigningOptions` 时没传
⇒ 走默认 `nil` ⇒ **缓存永远不生效**。引擎自带 CLI 是**默认开启**的
（`RorkSignCLI/ZSignCompatibleRunner.swift:357`，`.zsign_cache` + `readExistingEntries: !command.force`），
所以有现成的参考用法。

**它是安全的**（读过实现）：

- key 是**内容寻址**的（`BundleSignatureCache.makeKey`）：归一化后的未签名 Mach-O 字节 +
  `bundleIdentifier` + 签名模式（**证书 DER 哈希** + subject CN + team ID）+
  entitlements XML 哈希 + Info.plist 哈希 + CodeResources 哈希 + 哈希模式；
- 读回时**自校验**（`signedMachO(for:)` 把缓存里的已签名产物重新归一化再与 key 比对）；
- 写入是 **best-effort**（`store` 吞掉所有错误），缓存坏了不影响签名正确性。

**⚠️ 但有三条让它「不是一个 3 行改动」**：

1. **对「首次签一个大包」完全无效** —— 没有条目 ⇒ 必然 miss。它只帮**重复签同一份东西**
   （签名失败后重试、同一 App 同一账号再签）。用户抱怨的「签大包慢」是首次签署。
2. **存储代价 ~33% 膨胀**：条目是 `signedMachOBase64` 放在 JSON 里（base64 = 4/3）。
   780 MB 的 App ⇒ 缓存接近 **1 GB**。
3. **`SigningCacheOptions` 没有容量上限、没有淘汰**（只有 `directoryURL` + `readExistingEntries`）
   ⇒ 要上就得**自己实现上限 / 淘汰**，否则会持续吃用户存储。

⇒ 结论：**值得做，但要先设计「缓存放哪、上限多少、什么时候清」，不是顺手打开。**
留作独立一项，别塞进「提速」这一批。

## 杠杆 ③：deflate 打包

只有计时，没有优化。等 `打包完成（deflate），耗时` 的数字再判断值不值得动
（它和 `重签完成` 是**互斥**的两个候选：谁占大头就动谁）。

## 决定：先取证，再选一个杠杆

判据（拿到真机日志后按这个顺序读）：

1. 四行耗时里**最大的是哪一个**？
2. 若最大是 `重签完成（逐 Mach-O 串行）` ⇒ 杠杆 ①（引擎并发），代价最高，要单独立项；
3. 若最大是 `打包完成（deflate）` ⇒ 杠杆 ③；
4. 若最大是 `应用文件准备完成` ⇒ 那是 Seal 侧（`SigningWorkspace.prepare`），
   是**我们自己的代码**，改起来最安全 —— 优先看这里；
5. 若三者都不大 ⇒ 时间花在门户网络请求（App ID / 描述文件 / 证书）上，
   那属于另一条链路，与「大包」无关。

**在拿到这四行之前不动任何引擎代码。**

## 顺带确认（别重复怀疑）

- 峰值内存问题已在 `d571038` 处理过：`MachOFile.isMachO` **只读前 4 字节 magic**
  （`Bundle/BundleSigner.swift:1260-1280`），不再整体读入。
- 解压前按「解压后体积」判空间也已在 `d37e4297` / `c96a9982` 处理过。
