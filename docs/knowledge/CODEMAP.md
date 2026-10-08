# 代码地图

改功能时去哪找文件。

## 导入抽屉

- UI: `Seal/Features/Import/ImportConfirmationView.swift`
- 逻辑: `Seal/Features/Apps/AppsViewModel.swift` (consumeWorkflowState)
- 工作流: `Seal/Core/Import/ImportWorkflow.swift`

## 图标

- ViewModel 缓存: `AppsViewModel.iconData` + `decodedIconCache`
- 列表行: `Seal/Features/Apps/ImportedAppRow.swift`
- 签名页: `Seal/Features/Apps/AppSigningSheet.swift`
- 存储: `AppFileStore.storePreferredIcon`

## 应用名称

- ViewModel: `AppsViewModel.updatePreferredDisplayName`
- 编辑器: `AppSigningSheet.AppNameEditorSheet` (已改为 internal)
- 显示: `AppRecord.displayName` (preferredDisplayName ?? name)

## 续签

- 协调器: `Seal/Core/Renewal/RenewalCoordinator.swift`
- 快路径: `Seal/Core/Renewal/ProfileOnlyRenewalPolicy.swift`
- Seal 自注册: `Seal/Core/Renewal/SelfAppRegistrar.swift`

## 日志

- 存储: `Seal/Infrastructure/Diagnostics/SealLogStore.swift`
- 查看: `Seal/Features/Settings/LogViewerView.swift`
- 导出: `LogViewerView.exportLogs()` (读 Documents/Seal-log.txt)

## 标签（有更新待安装）

- 判据: `ProfileOnlyRenewalPolicy.hasPendingUpdateSource`
- 显示: `AppPresentation.pendingUpdateNote`
- Seal 清理: `SelfAppRegistrar` (SEAL-SELF-120)
