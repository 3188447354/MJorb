# 系统架构

## 三条链路

### 1. 导入链路

```
用户选 IPA
  → ImportWorkflow.prepare (解析 IPA)
  → ImportConfirmationView (抽屉：显示信息、改图标/名称)
  → workflow.confirm (提交)
  → ImportWorkflow.commit (创建/更新 AppRecord)
  → AppsViewModel.consumeWorkflowState (.completed)
    → 应用 pending 图标/名称
    → load() 刷新列表
```

关键类：
- `ImportWorkflow`: 状态机 (prepare → confirm → completed)
- `ImportDraft`: 解析结果 + 用户选择
- `AppRecord`: 持久化记录

### 2. 签名链路

```
用户点"签名并安装"
  → SigningCoordinator.signAndInstall
  → 准备：拉证书、描述文件 (Portal)
  → 重签：逐 Mach-O 签名 (CodeSignKit)
  → 打包：生成 signed IPA
  → 安装：MinimuxerInstallChannel 上传+安装
```

关键类：
- `SigningCoordinator`: 主协调
- `ProfileOnlyRenewalPolicy`: 快路径判据
- `SigningCertificateMaterialPolicy`: 证书复用判据

### 3. 续签链路

```
触发 (手动/后台/快捷指令)
  → RenewalCoordinator.process()
  → 对每个 App：
    → 判据：走 profile-only 还是完整重签
    → profile-only: 只换描述文件 (~4秒)
    → 完整重签：走签名链路 (~70秒)
  → 批量结果持久化
```

关键类：
- `RenewalCoordinator`: 批量协调 (actor)
- `ProfileOnlyRenewalPolicy.evaluate`: 准入判据
- `SelfAppRegistrar`: Seal 自身记录维护

## 数据流

```
AppRecord (CoreData)
  → AppsViewModel.apps ([AppRecord])
  → AppsViewModel.iconData ([UUID: Data])
  → SwiftUI View 显示
```

图标：
```
用户选图 → pendingImportIconData
  → 文件: AppFileStore.storePreferredIcon
  → 记录: AppRecord.preferredIconRelativePath
  → 内存: iconData[UUID]
  → 解码: decodedIconCache (UIImage)
```

## 通知

- `.sealRenewalCompleted`: 续签完成，停后台保活
- `.sealSelfRecordUpdated`: Seal 记录更新，刷新列表
