# AGENTS.md — Seal 项目工作纪律与约束

> 本文件是跨工具、跨会话的项目规则（含换 Trae 账号后继续工作的约定）。
> 所有对代码的改动请先读这里；「改动前自查清单」是硬门槛。
> 关联文档：`REWRITE_ROADMAP.md`（三链路取舍）、`DEBUG_LOG.md`（根因沉淀）、
> `SEAL_RELEASE_GUIDE.md`（发布手册）、`SIGNING_CHAIN_ANALYSIS_20260913.md`（签名链分析）。

## 0. 项目本质

本仓库以**签名 / 安装 / 续签**三条链路为焦点（自签 iOS 应用工具 Seal）。
改动常跨 Swift + Rust(Bridge) 两层，Windows 本机**无法编译**，一切以云 CI 编译 + 真机回归为准。
记忆/进度/规则存放在：本文件 + `DEBUG_LOG.md` + `REWRITE_ROADMAP.md`，换账号在仓库内即可接力。

## 1. 改动前必过自查清单（硬性，5 项缺一不可）

动手前必须逐条确认并有答案：

1. **做完结果会怎么样** —— 明确可验收的产出/行为变化。
2. **有没有遗漏** —— 边界、关联路径、未覆盖分支。
3. **会不会导致其他出错** —— 签名/续签/安装三环节尤其防互相牵连；回退/兜底是什么。
4. **规不规范** —— 与项目既有风格、`REWRITE_ROADMAP.md` 原则、Apple 官方规范一致。
5. **上游是否已有** —— Seal/AltStore/SideStore/jas/zsign 已有等价实现则优先对齐/复用，不自造轮子。

## 2. 代码规范

- **绿色基线**：离开工作区的改动必须能编译通过，绝不留下「调用了未定义函数/字段」的中间态。
- **最小改动**：只改目标所需，不顺手重构；对齐「删除为主、零新增 Rust」与「可回退双保险」。
- **根因不绕绕**：从真机日志定位根因再改，禁止 `--no-verify` 类绕行；现象→根因→修复→回归闭环。
- **大包内存纪律**：500MB+ 只流式处理（`unzipItem` 等），禁止整块载入内存。
- **错误码规范**：一律 `ImportFailure(title/reason/recovery/code)`，code 用 `SEAL-<模块>-<类别><序号>`
  （`INSTALL/PAIR/SIGN/AUTH/CERT/RENEW/APPID` 等），唯一且带可恢复引导。
- **跨层约束**：Swift↔Rust(Bridge) 改动先确认「上传与安装须同一缓存隧道会话」不变量
  （否则复现 `MissingPackagePath`）。

## 3. 三链路关键约束（改动必查）

### 签名
- 证书复用只允许剩余有效期 > 7 天（覆盖免费 profile 7 天寿命）：只剩「当下未过期」就复用，
  会把次日到期的证书签进新包 → iOS 判「尚未验证」闪退。四个复用分支（快速路径列表命中/网络失败、
  慢速路径选中/账户证书）都要过 `certificateReusable(_:)`。
- 签名/续签处于 LocalDevVPN 环境，无法可靠自动重登 Apple；会话过期统一引导到「我的」页重新验证，
  不要实现会触发 2FA 的签名页验证码路径。

### 安装
- 上传与安装必须在**同一条缓存 RemotePairing 会话**上（jas / IdeviceGateway 共同不变量）；
  跨会话一定 `MissingPackagePath`。
- **确定性拒绝必须立即终止、不得重传重试**：`isTerminalInstallError`（重试前判定）与
  `installationFailure`（最终归类）两张表必须**同一份词表**。免费账号设备级 3-app 上限的拒绝名是
  `ApplicationVerificationFailed`，等校验类错误名缺一个 → 大包空转重传 3 轮（单轮最长 40 分钟）。
  新增错误分类时先 grep 这两张表，两处必须同步。
- 存储不足（`No space left`/`ENOSPC`/`code 28`）显示「设备存储空间不足」而非 WiFi 提示。
- iOS 拒绝（3-app 上限、完整性校验、存储不足）用「知道了」按钮、立即终止、不重试。

### 续签
- 免费账号 3-app 上限是**设备级，跨不同 Apple ID/team 累计**（非每账号 3 个）；按住
  `account.isFreeTeam == true`、排除付费账号应用、排除自身、`>=3` 抛 `SEAL-APPID-DEVICELIMIT`。
- 批量续签（`refreshAll`）调 `signAndInstall` 必须传 `bypassFreeAccountDeviceLimit: true`（覆盖已装应用
  不新增槽位）；单签 `runSigning` 默认 false，靠「继续绕过」按钮传 true。
- 批量续签 `refreshFailedItems` 只重试上一轮失败的 App，不是全量。

## 4. 描述文件 / 证书 / 日志（近况高发区）

### 设备端描述文件
- 描述文件存在**手机系统 profile 存储**（profiled 进程），经 misagent 服务枚举/删除，**不属于任何 App 文件夹**。
- misagent 返回的是 **CMS 签名包裹的二进制**；Rust 解析不了会落盘为 `unknown_N.plist`。
  `DeviceProfileCleaner` **不能按扩展名过滤**，所有文件都交给 `ProvisioningProfileReader`（内置解 CMS）
  识别，并按 UUID 去重（LockDown 路径同一 profile 落 raw+plist 两份）。
- 设备端 profile 只增不删会累积到过期；安装/续签成功后按「签名包内 `embedded.mobileprovision` 的 UUID」
  清理**同一 Bundle ID** 的旧 profile，**严禁删全部**（会误删其他 app 的 profile 致连锁闪退）。
- 自更新（替换 Seal 自身）时进程会被系统杀掉——**清理必须在安装前做**（此刻新 profile 未落设备，
  匹配 bundle ID 的都是旧文件，删除安全、安装失败旧版也能开）。

### 证书
- 跨来源比对序列号必须**归一化（去前导零）**，否则误判「证书被轮换」。
- `signingIdentity` 本地快速路径复用前必须比对 Apple 服务器生效列表 + 有效期 > 7 天；
  网络失败回退本地证书也必须查有效期，过期不得复用。

### 日志
- 导出统一 `SealLogTextFormatter`：北京时间（Asia/Shanghai `yyyy-MM-dd HH:mm:ss`）+ 中文栏目。
- 容量环形 1000 条，满后滚动丢最旧并计数；导出头部注明「保留最近 N 条」，丢弃时补提示行。
- `SealLogStore` 每次 `flush()` 都镜像 `Seal-log.txt` 到 Documents（只镜像 error 会导致顺利操作无日志可查）。
- 日志导出/上报**不携带** keychain 凭据、Apple ID 明文。

## 5. 验证纪律

- **真机优先**：涉及安装/installd 的改动必须走回归样本（微信 / 黄豆短剧 / LCSign / lanmanga）真机验证；
  单测/编译通过 ≠ 可用。
- **自证**：不声称「已修复/已完成」直到有验证证据。
- 出错、修 bug、或发现常犯坑位 → 必须写进 `DEBUG_LOG.md` 顶部「历史记录」（现象→根因→修复→涉及文件→验证状态），
  坑位沉淀到「常犯坑位」节，动手前先查阅。

## 6. 版本与发布

- 凡「需发版让用户可检测到」的代码更新，必须 bump `MARKETING_VERSION`（`project.yml` 的 Seal 主 target
  与 SealTunnel 扩展**两处一致**）。内置更新比较 `CFBundleShortVersionString` 与 Release `tag_name`
  （支持 `1.0.13`/`v1.0.13` 前缀），Release tag 必须与 MARKETING_VERSION 对齐，否则检测不到。
  `CURRENT_PROJECT_VERSION` 由 CI `GITHUB_RUN_NUMBER` 覆盖，`project.yml` 里默认值不用手动改。
- 发布流程见 `SEAL_RELEASE_GUIDE.md`；`RELEASE_NOTES.md` 是每次发布正文来源。
- 跨仓库发 Release（源 `sunuannian1/Trae-seal` → 目标 `sunuannian1/Seal-Releases`）**不传 `--target`**，
  否则用源仓库 SHA 会 422（`target_commitish invalid`）。

## 7. CI / 工程约束

- `ios.yml` 完整档：RustBridge 一致性 + UI 回归 + 签名测试，大改动走它。
- `ios-release.yml` 快速档：Release 编译 + 发布，跳过 UI/rork 门，改 Swift 业务逻辑用。
- **触发方式**：`ios.yml` 除 PR 外，**推到非 `main` 分支、且改动命中相关路径也会自动编译**
  （`branches-ignore: [main]` + `paths` 过滤，纯文档推送会跳过）。`main` 由 `ios-fast.yml` 负责出包。
  `publish-release` 始终只在 `workflow_dispatch` + `publish_release=true` 时触发，**push 路径绝不自动发布**；
  该不变量由 `Scripts/verify-release-safety.py` 静态守护（含变异自检）。
- **时间预算（2026-09-14 实测）**：`ios.yml` 拆成 3 个并行 job —— `build-package`（编译 + 打包）、
  `swift-regression`（单测 + UI 回归）、`rork-sign-tests`。原先测试步骤嵌在 `build-package` 里，
  导致**同一份代码被全量构建两遍**（`xcodebuild test` 走 Debug、`build-unsigned-ipa.sh` 走 Release，
  两个配置的产物目录不同、DerivedData 增量互相用不上），再串行叠加一遍 UI 回归 → **20m33s**。
  拆开后墙钟时间取 max 而非 sum：**实测 9m38s**（build-package 8m59s / swift-regression 7m38s / rork 2m6s）。
  - **不要加「按路径判定是否跑测试」的闸门**。曾短暂加过 `classify-change`，实测无收益：
    `build-package` 比 `swift-regression` 还长，跳过测试省不到任何墙钟时间，却要承担漏跑 UI 回归的风险。
  - `publish-release` 的 `needs` **必须包含 `swift-regression`**：测试拆出去后若不同步加依赖，
    发布可能在 UI 回归还没跑完时就发出去（护栏已守护）。
- **构建 App 的 job 必须跑 `ensure-rustbridge.sh`**。本仓允许预编译 `RustBridge.xcframework` 落后于
  Rust 源码，该脚本按源码指纹发现不一致会**当场重编**。漏跑会链接到缺符号的旧库，报一堆
  `_rust_bridge_*` undefined symbols —— 2026-09-14 拆 job 时真实踩到（build-package 成功、
  swift-regression 链接失败）。护栏已守护 `build-package` 与 `swift-regression` 两处。
- **CI 失败原因必须能在不登录的情况下看到**：GitHub 原始日志需登录，注解不需要。
  `swift-regression` 把 `xcodebuild` 输出 `tee` 到 `build/TestLog.txt`，失败时由
  「Surface failures as annotations」步骤提炼成 `::error::` 注解。
- 改工作流触发条件前，先跑 `Scripts/verify-release-safety.py`，并确认 `publish-release` 的 `if:` 门未被削弱、
  `swift-regression` 的发布依赖与 `ensure-rustbridge.sh` 步骤仍在。
- CI 缓存「Refresh local SPM binary artifacts」只清 `SourcePackages/checkouts`，**不许 rm 整个 SourcePackages**
  （会删 OpenSSL.xcframework 二进制 → `openssl/err.h not found`）。
- CI 校验 `IPHONEOS_DEPLOYMENT_TARGET=17.0`；改部署目标时同步查 `ios.yml`/`ios-release.yml` 断言。