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
