# 决策记录

为什么这么做，避免重复讨论。

## 2026-10-10: App Group 数组做确定性排序

- **决策**：`assignAppGroups` 对映射后的 group ID 按默认字符串序（区分大小写）排序；写入 Info.plist `ALTAppGroups` 前同样排序；**上游签名器 `AppBundleSigner.prepare` 在写二进制前对 `com.apple.security.application-groups` 数组排序**（真正决定运行时行为的一处）。
- **为什么**：原包 entitlement 里 app-groups 数组的顺序是任意的，不同构建可能不同（实证：LiveContainer 主包与 LiveContainer2 的两个组集合相同、顺序相反）。运行时取第 0 个当共享目录，顺序不同会导致两个 App 用不同的共享目录、互相看不见。entitlement 数组顺序对 iOS 无语义，排序是归一化而非特例补丁。上游对照：AltStore/SideStore 不做 Seal 式 group 映射，无等价实现可对齐（记为"不跟"）。
- **为什么必须动签名器**：第一轮只改了 `assignAppGroups` 与 Info.plist，真机验证无效。根因有三：① 重签时 App ID「能力已满足」会跳过更新，assign 侧排序对已存在 App ID 无意义；② Apple 的 assign 端点不重排已有绑定；③ 实证 LiveContainer 读的是**二进制 entitlements 第 0 个**而非 Info.plist。签名器排序不依赖 Apple 侧顺序，每次签名结果确定；iOS 与 Seal 自检均按集合校验，安全。
- **代价**：若某 App 的第 0 个因排序翻转，其共享目录会整体迁移一次（老数据留在旧目录）。本案主包第 0 个排序前后不变，无影响。

## 2026-10-09: 证书 dismissal 只走统一入口

- **决策**：`SettingsViewModel.dismissCertificate(serialNumber:accountID:persistent:)` 是唯一入口，替代 `hide` / `removeRevoked` / `filterHidden` 三套命名。撤销成功或手动隐藏 → 持久化（UserDefaults）；撤销失败 → 仅内存移除；同步时 `filterDismissedCertificates` 统一过滤。
- **为什么**：MJ 明确要求「你设计正规的流程，不要左右手打架」——一个状态只走一条流程、一个入口。两套名字各行其是会导致隐藏与移除互相覆盖（撤销失败的证书还留在持久化隐藏里、手动隐藏的证书被同步带回来）。

## 2026-10-09: 「需重新签名」状态读路径加 30 秒覆盖层

- **决策**：签名成功写 `certificateAvailabilityOverride[appID] = (.ready, 现在)`；30 秒内读状态与后台重算都优先采用覆盖层，不查后台快照、不覆盖；30 秒后过期，后台接管。
- **为什么**：签名后 `load()` 后台读钥匙串（旧缓存）会把刚置的 `.ready` 盖回 `.needsFullResign`，跟签名成功那一笔打架，标签闪回「需重新签名」。刚签完本机一定有私钥，30 秒内直接信这一笔是安全的。

## 2026-10-08: 图标用双缓存而不是单缓存

- **决策**：`iconData` (原始 Data) + `decodedIconCache` (解码后 UIImage) 双缓存
- **为什么**：`UIImage(data:)` 解码很贵，列表滚动时重复触发。Data 小但解码慢，UIImage 大但显示快。
- **代价**：内存占用翻倍。已加硬上限 (10 张) 控制。

## 2026-10-07: 导入抽屉固定 580pt

- **决策**：不自适应高度，固定 580pt
- **为什么**：MJ 要求一次展示完整内容，不拉不滚。自适应在不同内容下跳动，体验差。

## 2026-10-06: 编译失败立马推

- **决策**：编译失败这类明确 bug，不用等 MJ 说"推"，直接修完推
- **为什么**：编译失败是客观错误，不是主观判断。等确认浪费 CI 时间。

## 2026-10-05: 标签判据与续签准入同源

- **决策**：UI 的"有更新待安装"标签，必须用 `ProfileOnlyRenewalPolicy.hasPendingUpdateSource` 同一套判据
- **为什么**：界面说"要重装"但准入走快路径（或反过来），用户会白等一次。两边必须一致。

## 2026-10-04: 不做 Mach-O 并行签名

- **决策**：签名阶段不并行
- **为什么**：完整重签里签名只占约 1 秒，并行至多省 0.5 秒（打包 3 秒、Portal 网络数秒、安装 10 秒+），不值得冒改 vendor CodeSigner 的风险。
