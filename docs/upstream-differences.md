# 上游（SideStore）↔ Seal 的差异表

- 生成：`python Scripts/gen-upstream-diff-table.py`（**请勿手改**）
- 上游版本：`43e052cd970cb16fed6b0bb4feeaec5e5d7efae7`（2026-09-19 04:08）
- 对照方法与台账：`docs/upstream-alignment.md` ✓

## ⚠️ 怎么读这张表

| 事实 | 含义 |
|---|---|
| Seal 167 个 Swift 文件 / 上游 401 个 | — |
| **同名文件只有 1 个** | ✗ 文件名对不上 ⇒ 只能按**功能**配对 |
| 文本相似度 **0.004–0.034** | ✗ **「一字一码」在文本层面做不到** |
| 本表 = **文件层面的存在性差异** | ✓ 不是逐行差异 |
| 功能层的对照结论 | 在 `docs/upstream-alignment.md` 的**台账**里 ✓ |

## 一、已知功能对（**唯一能做实质对照的地方**）

| Seal | 上游 | 相似度 | 改动行 | 台账结论 |
|---|---|---|---|---|
| `AnisetteClient.swift` | `OnDeviceAnisetteManager.swift` | 0.015 | 812 | 同上（Seal 的本地/远程双通道对应上游 ODA/远程） |
| `AnisetteClient.swift` | `AnisetteServersManager.swift` | 0.013 | 1184 |  |
| `AnisetteProvider.swift` | `AnisetteProvider.swift` | 0.121 | 145 | **跟** ✓（上游每次 fetch 都重新取，从不缓存） |
| `AnisetteServerStore.swift` | `AnisetteServersManager.swift` | 0.021 | 468 | 待对照 |
| `ApplePortalCertificateService.swift` | `UpdateAppCertificateOperation.swift` | 0.009 | 424 | **跟** ✓ 已实施 `ff718d9`（先创建、撞 3022 才撤销） |
| `ApplePortalCertificateService.swift` | `VerifyCertificateOperation.swift` | 0.034 | 570 |  |
| `ApplePortalCertificateService.swift` | `CacheSigningCertOperation.swift` | 0.032 | 420 |  |
| `ApplePortalSigningService.swift` | `FetchProvisioningProfilesOperation.swift` | 0.007 | 3147 | 见台账（anisette 刷新 / 节流 待定） |
| `ApplePortalSigningService.swift` | `RefreshAppOperation.swift` | 0.004 | 2744 |  |
| `ApplePortalSigningService.swift` | `PrepareAppExtensionBundleIDsOperation.swift` | 0.001 | 2698 |  |
| `MinimuxerInstallChannel.swift` | `InstallAppOperation.swift` | 0.017 | 1744 | 待对照 |
| `MinimuxerInstallChannel.swift` | `SendAppOperation.swift` | 0.009 | 1362 |  |

## 二、只在 Seal（166 个）

> 含两类：**Seal 独有功能**（上游没有 ✓）与**重命名的上游文件**（功能相同、名字不同 ✗）。

**Anisette / 设备环境**（6）：

```
AnisetteClient.swift
AnisetteData.swift
AnisetteDataProvider.swift
AnisetteProvisioningStore.swift
AnisetteServer.swift
AnisetteServerStore.swift
```

**Apple 门户 / App ID / 描述文件**（18）：

```
AccountAvailabilityPolicy.swift
AccountRepository.swift
AccountSecret.swift
AccountSelectionView.swift
AccountStatus.swift
AddAccountView.swift
AppleAccountClient.swift
AppleAccountDetailView.swift
AppleAccountRecord.swift
AppleAuthenticationDiagnosis.swift
ApplePortalInventoryService.swift
AppleServiceFailurePolicy.swift
AuthenticatedAppleAccount.swift
ProtectedAccountRepository.swift
ProvisioningEntitlementValue.swift
ProvisioningProfileBinding.swift
ProvisioningProfileReader.swift
TeamSelectionView.swift
```

**UI / 界面**（16）：

```
AboutView.swift
AppDetailView.swift
AppsRootView.swift
AppsViewModel.swift
FullIdentifierRow.swift
ImportConfirmationView.swift
ImportedAppRow.swift
NotificationSettingsView.swift
OpenSourceLicensesView.swift
PrivacyNoticeView.swift
RootTabView.swift
SealCommunityView.swift
SettingsFormatters.swift
SettingsRootView.swift
SettingsViewModel.swift
UpdateNoticeView.swift
```

**其它**（39）：

```
AppConfiguration.swift
AppContainer.swift
AppExtensionKind.swift
AppExtensionRecord.swift
AppPresentation.swift
AppRecord.swift
AppRecordRecovery.swift
AppSection.swift
AppState.swift
BlockingCall.swift
ContinuationBox.swift
CoreDataModel.swift
EnvironmentSnapshot.swift
EnvironmentStatusGlass.swift
ExpiryNotificationPlanner.swift
ExpiryNotificationScheduler.swift
GlassSurface.swift
HardTimeout.swift
ImportDraft.swift
ImportEmptyState.swift
ImportFailure.swift
ImportWorkflow.swift
ImportWorkflowState.swift
KeychainVault.swift
LocalNetworkPermissionPrimer.swift
NotificationPreferences.swift
NotificationScheduleStatus.swift
OperationCoordinator.swift
PendingBatchResultPayload.swift
ProfileReclaimPolicy.swift
SealApp.swift
SealAppearance.swift
SealBackdrop.swift
SealDrawer.swift
SealNotificationPresenter.swift
SelfManagedSealMigrationPolicy.swift
UpdateChecker.swift
VerificationCodeBroker.swift
Version.swift
```

**存储 / 文件**（13）：

```
AppFileStore.swift
AppStore.swift
AppStoreError.swift
ArchiveLimits.swift
ArchivePathValidator.swift
CompleteFileProtector.swift
CoreDataAppStore.swift
FileProtecting.swift
IPAParserService.swift
ParsedIPA.swift
StagedIPA.swift
StoredAppFiles.swift
UpdateIPADownloader.swift
```

**安装 / 设备通道**（17）：

```
DeviceProfileCleaner.swift
DeviceProfileInspector.swift
InstallChannel.swift
InstallChannelDiagnostic.swift
InstallStageBridge.swift
InstallStageTimeline.swift
InstallWaitNote.swift
InstalledAppActionSheet.swift
InstalledAppDeviceVerifier.swift
LocalDevVPNLink.swift
LocalDevVPNOnDemandActivator.swift
LocalDevVPNSettingsView.swift
MinimuxerInstallChannel.swift
PairingRecord.swift
PairingSettingsView.swift
PairingStore.swift
PreInstallValidation.swift
```

**日志 / 诊断**（3）：

```
LogPrivacyRedactor.swift
SealLogEntry.swift
SealLogStore.swift
```

**签名 / 重签**（9）：

```
BundleIDMapper.swift
BundleIDPolicy.swift
SideSignAppSigner.swift
SignedArtifactBundleIDReader.swift
SignedArtifactProfileReader.swift
SignedArtifactSnapshot.swift
SignedArtifactStatus.swift
SignedArtifactValidator.swift
SignedIPAIdentityReader.swift
```

**续签 / 自替换**（16）：

```
AppMaintenanceJob.swift
BatchRefreshSession.swift
BatchRefreshView.swift
MaintenanceGate.swift
RefreshPlanner.swift
RefreshQueueItem.swift
RefreshQueueStore.swift
RenewalCoordinator.swift
SelfAppIdentity.swift
SelfAppMetadata.swift
SelfAppRegistrar.swift
SelfReplacementCoordinator.swift
SelfReplacementPolicy.swift
SelfReplacementTransaction.swift
SelfReplacementTransactionStore.swift
StorageMaintenanceView.swift
```

**证书**（29）：

```
AppBundleSigningIdentityReader.swift
AppSigningSheet.swift
ApplePortalCertificateService.swift
ApplePortalSigningService.swift
CertificateCleanupPolicy.swift
CertificateExportHandler.swift
CertificateHealthStatus.swift
CertificateRequestFailurePolicy.swift
CertificateRevocationImpact.swift
CertificateTakeoverPolicy.swift
CertificatesRootView.swift
PortalSigningResult.swift
PreparedSigningWorkspace.swift
SelfSigningIdentity.swift
SigningAndRenewalGuideView.swift
SigningCertificateMaterialPolicy.swift
SigningCertificateSelectionPolicy.swift
SigningCertificateSettingsView.swift
SigningCoordinator.swift
SigningHistoryRecord.swift
SigningHistoryStore.swift
SigningPreferenceStore.swift
SigningProgressBudget.swift
SigningProgressView.swift
SigningSession.swift
SigningStage.swift
SigningTargetRecord.swift
SigningWorkspace.swift
X509CertificateValidityReader.swift
```


## 三、只在上游（400 个）

> **这是最值得看的一栏** —— 上游有而 Seal 没有的东西里，可能藏着「Seal 应该实现但漏了」的功能 ✓。

**Anisette / 设备环境**（6）：

```
AnisetteConfigManager.swift
AnisetteDataView.swift
AnisetteManager.swift
AnisetteServerList.swift
AnisetteServersManager.swift
OnDeviceAnisetteManager.swift
```

**Apple 门户 / App ID / 描述文件**（16）：

```
Account.swift
AccountVerificationRow.swift
AppID.swift
AppIDDetailView.swift
AppIDsListView.swift
AppIDsViewController.swift
CustomAppIDAlertViewController.swift
DeveloperPortalProxy.swift
ExportAccountAlertViewController.swift
FetchProvisioningProfilesOperation.swift
ImportAccountAlertController.swift
ImportedAccount.swift
ProfilePortalDetailView.swift
SelectTeamViewController.swift
SyncAppIDsOperation.swift
Team.swift
```

**UI / 界面**（99）：

```
ActivityViewController.swift
AddSourceTextFieldCell.swift
AddSourceViewController.swift
AltAppIconsViewController.swift
AppBannerCollectionViewCell.swift
AppBannerView.swift
AppCardCollectionViewCell.swift
AppContentViewController.swift
AppContentViewControllerCells.swift
AppDetailCollectionViewController.swift
AppExtensionView.swift
AppGroupsListView.swift
AppIconImageView.swift
AppInfoView.swift
AppScreenshotCollectionViewCell.swift
AppScreenshotsViewController.swift
AppViewController.swift
AuthenticationViewController.swift
BackupAndRestoreView.swift
BonjourDiscoveryView.swift
BonjourDiscoveryViewModel.swift
BrowseViewController.swift
CacheManagementView.swift
CacheViewModel.swift
CellContentCell.swift
CellContentChange.swift
CellContentDataSource.swift
CellContentPrefetchingDataSource.swift
CellContentUpdateableView.swift
CodeResourcesViewer.swift
CollapsingMarkdownView.swift
CollapsingTextView.swift
ConnectionConfigView.swift
ContentView.swift
CreateManualProfileView.swift
DeleteAppAlertViewController.swift
DeveloperOptionsView.swift
DeveloperServicesView.swift
DeveloperServicesViewModel.swift
DirectoryExplorerView.swift
ErrorDetailsViewController.swift
ExperimentalFeaturesView.swift
FeaturedComponents.swift
FeaturedViewController.swift
HeaderContentViewController.swift
HealthCheckView.swift
HealthCheckViewModel.swift
InfoPlistContainerView.swift
InfoPlistCustomizationCoreView.swift
InfoPlistCustomizationSheetView.swift
InfoPlistCustomizationView.swift
InsetGroupTableViewCell.swift
InstructionsViewController.swift
LaunchViewController.swift
LicensesViewController.swift
MyAppsViewController.swift
NewsCollectionViewCell.swift
NewsViewController.swift
NibView.swift
OnboardingView.swift
PatreonViewController.swift
PlaceholderView.swift
PreviewAppScreenshotsViewController.swift
PrivateKeyTextInputView.swift
ProfileManagementView.swift
ProfileManagementViewModel.swift
ProfilesListView.swift
ResetAdiAlertViewController.swift
ResignAltStoreViewController.swift
ReviewPermissionsViewController.swift
RevokeAlertViewController.swift
ScreenshotCollectionViewCell.swift
SelectProfileViewController.swift
SetProfileAlertViewController.swift
SettingsHeaderFooterView.swift
SettingsViewController.swift
SideJITServerConfigView.swift
SourceDetailContentViewController.swift
SourceDetailViewController.swift
SourceHeaderView.swift
SourcesViewController.swift
SplashView.swift
StorageExplorerView.swift
StorageExplorerViewModel.swift
TextCollectionReusableView.swift
ThemePickerView.swift
ToastView.swift
UICollectionView+CellContent.swift
UITableView+CellContent.swift
UIView+AnimatedHide.swift
UIView+Pinning.swift
UIViewController+WebURL.swift
UnsupportedWidgetView.swift
UpdateCollectionViewCell.swift
UserCustomizationsView.swift
View+AltWidget.swift
ViewAppIntentHandler.swift
WirelessPairView.swift
WirelessPairViewModel.swift
```

**其它**（178）：

```
ALTAppPermission.swift
ALTAppPermissions.swift
ALTLocalizedError.swift
ALTPatreonBenefitID.swift
ALTSourceUserInfoKey.swift
ALTWrappedError.swift
AbstractClassError.swift
ActiveAppsTimelineProvider+Simulator.swift
ActiveAppsTimelineProvider.swift
ActiveAppsWidget.swift
AppBootManager.swift
AppConstants.swift
AppDelegate.swift
AppDetailWidget.swift
AppManager.swift
AppManagerErrors.swift
AppOperation.swift
AppPermission.swift
AppPermission11To17_1MigrationPolicy.swift
AppPermission17To17_1MigrationPolicy.swift
AppPermissionProtocol.swift
AppPermissionsCard.swift
AppProtocol.swift
AppScreenshot.swift
AppShortcuts.swift
AppSnapshot.swift
AppSorting.swift
AppVersion.swift
AppsTimelineProvider.swift
ArrayDataSource.swift
AsyncManaged.swift
AsyncOperation.swift
AuthManager.swift
BackgroundAudioService.swift
BackgroundLocationService.swift
BackgroundService.swift
BackgroundTaskManager.swift
BackupEngine.swift
BaseEntity.swift
BonjourDiscoveryManager.swift
BonjourDiscoveryTypes.swift
BuildInfo.swift
Button.swift
CacheAppOperation.swift
CacheManager.swift
CacheResignedMetadataOperation.swift
ChangeAppIconOperation.swift
CleanStagedAppOperation.swift
ClearAppCacheOperation.swift
CompositeDataSource.swift
ConnectionConfig.swift
CoreDataHelper.swift
Countdown.swift
CreateIpaOperation.swift
DataStructuresTests.swift
DatabaseManager.swift
Date+RelativeDate.swift
Date+Widget.swift
DateTimeUtil.swift
DeactivateAppOperation.swift
DownloadAppOperation.swift
DynamicDataSource.swift
EMProxyWrapper.swift
EnableJITOperation.swift
ErrorProcessing.swift
ExportResignedIpaOperation.swift
FetchSourceOperation.swift
Fetchable.swift
FetchedResultsDataSource.swift
ForwardingNavigationController.swift
ImportExport.swift
InjectBatchProfilesOperation.swift
IntentHandler.swift
JSONDecoder+Properties.swift
Keychain.swift
KnownSource.swift
LinkedHashMap.swift
LinkedHashMapTests.swift
LoadingState.swift
LocalNetworkPermissionChecker.swift
LockScreenWidget.swift
Managed.swift
MarkAppInactiveOperation.swift
MergePolicy.swift
MyAppsComponents.swift
NSAttributedString+Markdown.swift
NSError+ALTServerError.swift
NSPredicate+Search.swift
NavigationBar.swift
NewsItem.swift
OCSPValidator.swift
OperatingSystemVersion+Comparable.swift
OperationContexts.swift
OperationError.swift
OperationStep.swift
OperationStepDefinition.swift
OptionalProtocol.swift
OutputStream.swift
PageInfoManager.swift
PaginationDataHolder.swift
PaginationIntent.swift
PatchInfoPlistOperation.swift
PerformBackupRestoreOperation.swift
PersistentContainer.swift
PillButton.swift
PipelineExecutionHandler.swift
PipelineExecutor.swift
PipelineHandler.swift
PipelineRunner.swift
PreflightChecksOperation.swift
PresenterProvider.swift
PrivateKeyTextEditor.swift
ProcessError.swift
ProcessInfo+Platform.swift
ProcessInfo+Previews.swift
ProfileManager.swift
Regex+Permissions.swift
RelationshipPreservingMergePolicy.swift
ReleaseTrack.swift
ReleaseTrack11To17_1MigrationPolicy.swift
ReleaseTrack17To17_1MigrationPolicy.swift
RemoveAppExtensionsOperation.swift
RemoveAppOperation.swift
RemoveBackupDataOperation.swift
ResignAppOperation.swift
Result+Conveniences.swift
SceneDelegate.swift
ScheduleExpirationWarningNotificationOperation.swift
SecureValueTransformer.swift
SelectAppIntent.swift
SendAppOperation.swift
SideBackupApp.swift
SideJITManager.swift
SingletonGenericMap.swift
Source.swift
Source11To17MigrationPolicy.swift
Source11To17_1MigrationPolicy.swift
Source17To17_1MigrationPolicy.swift
SourceComponents.swift
SourceError.swift
StageAppOperation.swift
StageBackupAppOperation.swift
StandaloneExecutionHandler.swift
String+Localization.swift
SuffixEnforcedTextField.swift
TabBarController.swift
TaskChainCoalescer.swift
TaskChainSerializer.swift
TaskMutexSerializer.swift
ThemeManager.swift
TreeMap.swift
TreeMapTests.swift
UIAlertAction+Actions.swift
UIApplication+AppExtension.swift
UIColor+Hex.swift
UIFontDescriptor+Bold.swift
UIImage+Manipulation.swift
UIKit+ActivityIndicating.swift
UINavigationBarAppearance+TintColor.swift
UIScreen+CompactHeight.swift
UISpringTimingParameters+Conveniences.swift
UISwitch+tvOS.swift
UITests.swift
UITestsLaunchTests.swift
URL+Normalized.swift
URLHandler.swift
UninstallAppOperation.swift
UpdateKnownSourcesOperation.swift
UserCustomizationOperation.swift
UserInfoValue.swift
VerificationError.swift
VerifyAppOperation.swift
VibrantButton.swift
WidgetDataManager+CoreData.swift
WidgetDataManager.swift
WidgetModels.swift
WidgetUpdateIntent.swift
WirelessPairTargetDialog.swift
```

**存储 / 文件**（24）：

```
ALTApplication+AltStoreApp.swift
AltStore+Async.swift
ArchiveFingerprint.swift
CFNotificationName+AltStore.swift
FileManager+Backups.swift
FileManager+DirectorySize.swift
FileManager+SharedDirectories.swift
FileManager+URLs.swift
FileOutputStream.swift
INInteraction+AltStore.swift
NSError+AltStore.swift
ProcessInfo+AltStore.swift
SideStoreTopShelfProvider.swift
StoreApp.swift
StoreApp10ToStoreApp11Policy.swift
StoreApp11To17MigrationPolicy.swift
StoreApp11To17_1MigrationPolicy.swift
StoreApp17To17_1MigrationPolicy.swift
StoreAppPolicy.swift
StoreCategory.swift
TVWebFileTransferManager.swift
UIColor+AltStore.swift
UTType+AltStore.swift
UserDefaults+AltStore.swift
```

**安装 / 设备通道**（13）：

```
DeviceRegistrationFlow.swift
DevicesListView.swift
InstallAppDialog.swift
InstallAppOperation.swift
InstalledApp.swift
InstalledAppPolicy.swift
InstalledAppsCollectionHeaderView.swift
InstalledExtension.swift
MinimuxerWrapper.swift
PairingFileManagementView.swift
PairingFileManager.swift
PairingWebUploadServer.swift
UIDevice+Vibration.swift
```

**日志 / 诊断**（14）：

```
AltWidgetLogging.swift
ConsoleLog.swift
ConsoleLogView.swift
ConsoleLogger.swift
ErrorLogTableViewCell.swift
ErrorLogViewController.swift
LoggedError.swift
Logger+AltStore.swift
OSLog+SideStore.swift
OperationLogging.swift
OperationsLoggingControl.swift
OperationsLoggingControlView.swift
SideStoreLogging.swift
WidgetLogManager.swift
```

**签名 / 重签**（19）：

```
AltWidgetBundle.swift
AppBundleFingerprint.swift
Bundle+AltStore.swift
Bundle+AppExtension.swift
BundleResourceBrowserView.swift
CodeSignValidationFlow.swift
CodeSignValidator.swift
EntitlementsCustomizationCoreView.swift
EntitlementsCustomizationSheetView.swift
EntitlementsCustomizationView.swift
EntitlementsCustomizationViewModel.swift
MachOResourceViewer.swift
OperationEntitlements.swift
PrepareAppExtensionBundleIDsOperation.swift
SideSignConfigManager.swift
SideSignConfigurationView.swift
SignInFlowHandler.swift
SignInOperation.swift
SignOutAlertViewController.swift
```

**续签 / 自替换**（9）：

```
BackgroundRefreshAppsOperation.swift
CellularRefreshManager.swift
MaintenanceManager.swift
RefreshAllAppsIntent.swift
RefreshAllAppsWidgetIntent.swift
RefreshAppOperation.swift
RefreshAttempt.swift
RefreshAttemptsViewController.swift
RefreshGroup.swift
```

**证书**（22）：

```
ActiveCertSectionView.swift
CacheSigningCertOperation.swift
CertificateASN1Parser.swift
CertificateDetailView.swift
CertificateExporter.swift
CertificateManager.swift
CertificatePortalDetailView.swift
CertificateProvisioningFlow.swift
CertificateRowView.swift
CertificateStore.swift
CertificateTypes.swift
CertificatesListView.swift
CertificatesPortalListView.swift
CertificatesView.swift
CertificatesViewModel.swift
EmbedSigningCertOperation.swift
ExportCertificateDialog.swift
RevokeCertificatesAlertViewController.swift
SetCertificateAlertViewController.swift
SignableCertificatesListViewController.swift
UpdateAppCertificateOperation.swift
VerifyCertificateOperation.swift
```
