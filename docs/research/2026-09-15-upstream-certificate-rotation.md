# 上游证书轮换与全新描述文件调研（2026-09-15）

## 结论

`ALTAppleAPIErrorDomain code=3022` 是 AltSign 自己的 `ALTAppleAPIError.tooManyCertificates` 枚举值；Apple 私有接口实际返回的是 `resultCode=7460`。AltSign 在创建证书接口中把 7460 映射为 3022。因此当前真机日志不是模糊的 CSR 错误，而是已确认的证书数量上限。

上游 AltStore 和 SideStore 对“门户已有证书，但本机没有相应私钥”的处理一致：不能从 Apple 门户恢复私钥；必须复用本地保存的 P12/私钥，或者撤销旧证书、创建由本机生成私钥的新证书，再立即重签并安装自身。它们不会在 3022 后继续重复创建证书。

对于免费团队，SideStore 会默认选中全部现有 iOS Development 证书进行撤销，再创建新证书；AltStore 会选择现有的 AltStore 证书，否则取第一个证书，撤销成功后创建新证书。两者都把“自更新”当作一次完整安装，而不是仅刷新描述文件，确保新安装使用新证书。

## 一手源码证据

### 1. 3022 的真实含义

- AltSign 的 `ALTAppleAPIError` 从 3000 顺序编号，`tooManyCertificates` 对应 3022：[ALTErrors.swift L30-L54](https://github.com/SideStore/AltSign/blob/35b68f1aafaa038fd012b11d5acb71e6394c9c25/Sources/ALTErrors.swift#L30-L54)。
- `submitDevelopmentCSR.action` 返回 `resultCode=7460` 时，AltSign 映射成 `.tooManyCertificates`：[ALTAppleAPI+Operations.swift L183-L225](https://github.com/SideStore/AltSign/blob/35b68f1aafaa038fd012b11d5acb71e6394c9c25/Sources/ALTAppleAPI%2BOperations.swift#L183-L225)。

因此 Seal 应把 `domain=ALTAppleAPIErrorDomain code=3022` 和底层 `resultCode=7460` 作为同一个确定性容量错误处理，不能把它当成 `invalidCertificateRequest`，也不能原样重试创建。

### 2. 外部证书私钥无法从门户补回

- AltSign 在设备本地生成 CSR 和私钥，`ALTCertificateRequest` 同时保存 `csr` 和 `privateKey`：[ALTCertificateRequest.swift L10-L45](https://github.com/SideStore/AltSign/blob/35b68f1aafaa038fd012b11d5acb71e6394c9c25/Sources/Model/ALTCertificateRequest.swift#L10-L45)。
- 创建证书后，AltSign 把本次 CSR 的本地私钥附到 Apple 返回的 X.509 证书上；重新列举门户证书只能取回公钥证书信息：[ALTAppleAPI+Operations.swift L202-L228](https://github.com/SideStore/AltSign/blob/35b68f1aafaa038fd012b11d5acb71e6394c9c25/Sources/ALTAppleAPI%2BOperations.swift#L202-L228)。
- Apple 官方也要求从证书创建者导出包含私钥的 PKCS#12，再导入本机；门户不能下载该私钥：[Synchronizing code signing identities](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)。

因此爱思助手创建的证书只有两条可行路径：爱思助手导出 P12 给 Seal，或 Seal 撤销它并创建自己的证书。仅凭相同 Apple ID 无法重建原私钥。

### 3. AltStore 的轮换实现

- AltStore 先按顺序尝试本机 Keychain P12、旧版“序列号 + 私钥”、App 内嵌 P12；只有门户证书仍存在且本机能提供私钥才复用：[AuthenticationOperation.swift L543-L578](https://github.com/altstoreio/AltStore/blob/56854e66fef2eac32dad88dcbad1dc131d430e60/AltStore/Operations/AuthenticationOperation.swift#L543-L578)。
- 门户为空时直接创建；门户非空而本机没有任何私钥时，明确执行“撤销一个证书，再创建新证书”：[AuthenticationOperation.swift L527-L589](https://github.com/altstoreio/AltStore/blob/56854e66fef2eac32dad88dcbad1dc131d430e60/AltStore/Operations/AuthenticationOperation.swift#L527-L589)。
- AltServer 安装侧采用同样策略，并明确提示继续会使其他 AltServer/Xcode 安装失效；撤销成功才调用 `addCertificate()`：[ALTDeviceManager+Installation.swift L481-L606](https://github.com/altstoreio/AltStore/blob/56854e66fef2eac32dad88dcbad1dc131d430e60/AltServer/Devices/ALTDeviceManager%2BInstallation.swift#L481-L606)。
- 新签名证书与当前 AltStore 描述文件不一致时，AltStore要求立刻重装自身；代码明确使用 `install` 而不是 `refresh`，以确保装入非撤销证书：[RefreshAltStoreViewController.swift L31-L69](https://github.com/altstoreio/AltStore/blob/56854e66fef2eac32dad88dcbad1dc131d430e60/AltStore/Authentication/RefreshAltStoreViewController.swift#L31-L69)。

### 4. SideStore 的新实现

- SideStore 先列举门户证书并尝试匹配本地活动 P12或运行中 App 的可签名缓存；门户有证书但本机没有私钥时，进入替换流程，而不是先提交一个必然失败的新增请求：[CertificateProvisioningFlow.swift L78-L111](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/SideStore/Core/Auth/Flows/CertificateProvisioningFlow.swift#L78-L111)。
- 替换流程只处理 iOS Development/iPhone Developer 证书；逐个撤销成功后才创建新证书，并重新列举门户来补全新证书元数据，同时保留本次创建产生的私钥：[CertificateProvisioningFlow.swift L114-L191](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/SideStore/Core/Auth/Flows/CertificateProvisioningFlow.swift#L114-L191)。
- 免费团队的撤销选择器默认选择全部现有证书，且不给逐项取消；付费团队才允许用户选择具体证书：[RevokeCertificatesAlertViewController.swift L13-L30](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/SideStore/Views/Settings/Auth/RevokeCertificatesAlertViewController.swift#L13-L30) 及 [L52-L73](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/SideStore/Views/Settings/Auth/RevokeCertificatesAlertViewController.swift#L52-L73)。
- SideStore 对运行中证书做单独校验，区分“免费账户自动撤销”“私钥丢失”“外部工具签名”等状态：[CodeSignValidator.swift L41-L109](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/SideStore/Core/Certificates/CodeSignValidator.swift#L41-L109)。
- 发生证书更换后，SideStore同样用完整 `install` 重装自身；源码注释说明安装完成会终止 SideStore，之后可立即重新打开：[ResignAltStoreViewController.swift L123-L169](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/AltStore/Authentication/ResignAltStoreViewController.swift#L123-L169)。

### 5. 全新 7 天描述文件

- AltSign 的 profile 请求走 `ios/downloadTeamProvisioningProfile.action`，由 App ID 和平台重新向 Apple 下载：[ALTAppleAPI+Operations.swift L523-L558](https://github.com/SideStore/AltSign/blob/35b68f1aafaa038fd012b11d5acb71e6394c9c25/Sources/ALTAppleAPI%2BOperations.swift#L523-L558)。
- AltStore 的策略是先 fetch，再尝试 delete + 第二次 fetch；源码注明自 2023-03-20 起免费 profile 每次 fetch 都会重新生成且不能删除，所以删除失败时直接使用第一次 fetch 的新 profile：[FetchProvisioningProfilesOperation.swift L501-L529](https://github.com/altstoreio/AltStore/blob/56854e66fef2eac32dad88dcbad1dc131d430e60/AltStore/Operations/FetchProvisioningProfilesOperation.swift#L501-L529)。
- SideStore 当前管线为主 App 与每个扩展分别注册/更新 App ID 后再下载 profile，并记录 Apple 返回的到期时间：[FetchProvisioningProfilesOperation.swift L147-L195](https://github.com/SideStore/SideStore/blob/9ee1899a04b03dc0d0f66ebf5a61b41f1b49a68d/SideStore/Core/Operations/PipelineOperations/FetchProvisioningProfilesOperation.swift#L147-L195)。
- Apple Developer Forums 的 Apple 体系说明确认 Personal Team 免费描述文件有效期为一周，期满需要重新创建：[Apple Developer Forums accepted answer](https://developer.apple.com/forums/thread/80674)。

上游只请求并使用 Apple 返回的新 profile，没有强制检查“从当前时间起至少还剩完整 7×24 小时”。Seal 的验收要求更严格，应该在签名前检查每个主 App/扩展 profile：证书序列号包含本次新证书、UDID/Bundle ID 正确、`ExpirationDate - CreationDate` 约为 7 天，并且 `ExpirationDate - now` 达到允许网络耗时误差后的完整周期；不符合就停止使用该 profile，并在同一 session 内重新 fetch 一次。不能把旧 profile 作为网络失败回退。

## 建议落地到 Seal 的最小链路

1. 在任何撤销前完成登录 session、团队、设备连接/配对、目标 IPA 与 Bundle ID/扩展枚举等只读预检。
2. 列举门户证书，按序列号匹配 Seal 本地 P12/私钥；本地私钥有效且证书剩余期超过 7 天才复用。
3. 免费团队若门户已有证书但没有任何匹配私钥，直接进入“容量轮换”，把 3022/7460 当作此前预检遗漏后的同一恢复分支，不重复 `addCertificate`。
4. 轮换前持久化事务日志（账号/team、旧证书序列号、目标 App、阶段）；撤销成功后立刻创建新证书并原子保存 P12，再重新 fetch 门户验证序列号与有效期。
5. 主 App 和全部扩展重新向 Apple 获取 profile，并校验证书、Bundle ID、设备、CreationDate/ExpirationDate；任何一个旧 profile 都不能混入签名包。
6. 用新证书重签，安装时保持上传与安装使用同一缓存配对会话。Seal 自身必须走完整 install 路径；安装启动后系统终止旧进程属于预期。
7. 下次启动按事务日志和运行包内 embedded profile/X.509 核验新证书、新 profile，再清理旧状态；被旧证书影响的同账号应用随后逐一重签。

对应本仓落点：`ApplePortalSigningService.signingIdentity` 应把当前 723-780 行“外部 Seal 先尝试新增、3022 后抛 SEAL-CERT-221”替换成上游的预检轮换；`SigningCoordinator.signAndInstall` 的 204a-204d 恢复分支应同时接管 SEAL-CERT-221/精确 3022，并在已经确定当前目标使用无钥匙证书时建立轮换事务；`ApplePortalSigningService.fetchProvisioningProfile` 应增加 profile 证书/日期/Bundle ID/设备后置校验。现有 `revokeKeylessCertificatesAfterConfirmation` 可复用撤销与受影响 App 枚举，但自签场景需要专门的“撤当前 Seal 证书后立即创建、签名、完整安装”事务，不能继续在该函数内无条件跳过运行中 Seal 证书。

## 风险边界

- Apple 明确说明，撤销证书会使包含该证书的 provisioning profile 失效：[Revoke a certificate](https://developer.apple.com/help/account/certificates/revoke-a-certificate)。因此在外部证书私钥确实不存在、免费账户又无空余证书槽位时，不存在“旧证书继续有效，同时无风险创建新证书”的原子方案。上游也只能采取撤销后立即创建、重签、完整安装来缩短失效窗口。
- 撤销会同时影响同一证书签过的其他 App/其他设备。Seal 应记录受影响应用并在自身重装成功后连续续签；但如果进程、网络或系统在撤销后、新安装前中断，仍可能需要原签名工具重新安装 Seal。这是 Apple 证书模型限制，代码无法彻底消除。
- 只看到 profile 显示“7天”不够。最终验收应解析安装包内 `embedded.mobileprovision` 和叶证书，核对新 UUID、CreationDate、ExpirationDate、DeveloperCertificates 序列号，再在安装后从设备 profile 存储复核。
