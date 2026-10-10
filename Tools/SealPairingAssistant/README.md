# Seal 配对助手

Windows 配对助手基于上游 [`jkcoxson/idevice_pair`](https://github.com/jkcoxson/idevice_pair) 0.1.14
（commit `e3abb341b73a4fbeb96cdfc5e6652687e4bee130`）二次开发。上游负责真实设备协议；
Seal 负责产品 UI、iOS 版本分流、中文状态、Windows 图标和将配对凭据安全交接给 Seal 的集成层。

## v16 报错一律走弹窗

- **所有报错都以居中模态弹窗呈现**：写明「问题 / 原因 / 解决办法」，并提供「重新检测」或
  「重新生成配对文件」与「知道了」。
- **页面不再复述报错**：删除了原先画在页面上的红色提示条；标题区与状态徽章只保留中性状态
  （配对未完成 / 检查设备状态 / 未完成），把原因和解决办法全部让给弹窗。
- 三项检查行的失败措辞改为中性的「未就绪」，不再出现“检测失败 / 检查失败 / 写入失败”。
- **同一个问题只弹一次**：`seal_raise_issue` 以 `seal_issue_seen` 去重；该问题被解决
  （无线调试启用成功、开发者模式读到开启、DDI 挂载成功、设备重新上线、配对文件重新生成成功、
  写入 Seal 成功等）后才允许再次弹出，避免轮询把弹窗反复推回。
- 报错文案与解决办法集中在 `seal_issue_model.rs.txt` 的 `SealIssue` 构造器里，
  **共 21 类**：连接与后台（4）、设备环境（4）、配对生成（5）、交接写入（7）、校验（1）。
- **一处不落**：上游只写日志、界面上看不见的静默报错也全部接上弹窗——设备列表逐个探测失败、
  读取设备信息（iOS 版本）失败、已安装应用列表读取失败、配对文件校验失败。
  唯一例外是 `src/discover.rs` 的 mDNS 启动用 `expect()` 直接 panic（上游行为，只影响局域网发现）。
- `patch_upstream.py` 的 `verify()` 强制校验弹窗模型、触发点是否齐全，并禁止旧的页面内联
  报错文案（`Seal 未收到配对文件` / `notice_rect` / `"写入失败"` / `"检测失败"` / `"检查失败"`）回归。

## v15 产品界面与交接闭环

- 使用 Seal 当前的羽毛 AppIcon 作为窗口 / 任务栏 / EXE 图标，并从同一源图生成内容区纹理。
- 只使用 Seal 羽毛图标作为窗口 / 任务栏标识；不使用手机模型或内容区装饰图标。
- 主界面以当前设备为主体，展示“连接 → 检查 → 生成 → 交接”四个真实阶段。
- 每个阶段的文本仅陈述已收到的设备协议状态；失败原因与解决办法一律进弹窗，页面上只留中性状态，不把上游英文错误伪装成成功。
- 成功状态明确提示“现在可关闭此窗口”，并提示用户回到 Seal 继续操作；不把尚未完成的首次真实设备验证伪装成已验证。
- 删除界面上的原始配对材料、日志、语言切换、配对准备分组、生成分组、写入已安装应用等入口。
- 开发者模式、无线调试与开发者支持文件各自显示真实检测状态；其他协议细节只在需要用户处理时出现。
- **配对类型不让用户选，按设备系统版本自动决定**（`seal_mode_for_ios`）：
  **iOS 17.4 及以上** ⇒ 远程配对（RPPairing）；**iOS 17.0–17.3.1** ⇒ 本机配对（Lockdown）；
  版本未读到时禁用生成按钮，直到读取完成，绝不误用上游默认的远程配对。
  判据：**iOS 17.4 才引入 `CoreDeviceProxy`**，更早的系统在 USB 上引导不了远程配对。
- 主按钮使用“开始配对”；文件生成后仍自动安全交接给 Seal，不把后台协议步骤重复写进按钮。

## 保留的上游真实链路

- USB 自动发现 iPhone/iPad
- Lockdown pairing
- RPPairing / CoreDeviceProxy / RSD
- 无线调试
- Developer Mode 检测
- Developer Disk Image 自动挂载
- Pairing 文件生成、加载、保存、验证
- Seal 直接写入

界面底部与随附说明文件均披露上述上游来源和版本；Seal 不替换、不伪造这些设备协议实现。

Seal 使用 `SealPairing.mobiledevicepairing` 作为 Documents 收件文件。Seal 会自动导入；手动导入继续作为恢复入口。

## Windows 前置条件

按上游要求使用 Apple 官网 Windows iTunes / Apple Mobile Device 组件提供 usbmuxd 通道。
不再要求用户手工复制 `idevice_id.exe`、`idevicepair.exe`、`ideviceinfo.exe`。

## 上游固定版本

- repository: `jkcoxson/idevice_pair`
- commit: `e3abb341b73a4fbeb96cdfc5e6652687e4bee130`
- version: `0.1.14`
- license: MIT
