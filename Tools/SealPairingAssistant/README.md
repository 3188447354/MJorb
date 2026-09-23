# Seal 配对助手

Windows 配对助手固定使用上游 `jkcoxson/idevice_pair` 的真实设备协议实现，Seal 只增加品牌、素材、视觉和 App 集成层。

## v14 前端定稿

- 使用 Seal 图标作为窗口 / 任务栏 / EXE 图标。
- 主界面逐项对齐已审核 HTML：标题、状态、设备、进度、检查项、提示、UDID、主操作。
- 删除界面上的日志、语言切换、配对准备分组、生成分组、写入已安装应用等入口。
- 正常状态隐藏无线调试、开发者模式、开发者磁盘映像、配对类型等细节；异常时只显示需要处理的项目。
- **配对类型不让用户选，按设备系统版本自动决定**（`seal_mode_for_ios`）：
  **iOS 17.4 及以上** ⇒ 远程配对（RPPairing）；**iOS 17.0–17.3.1** ⇒ 本机配对（Lockdown）；
  版本未读到时禁用生成按钮，直到读取完成，绝不误用上游默认的远程配对。
  判据：**iOS 17.4 才引入 `CoreDeviceProxy`**，更早的系统在 USB 上引导不了远程配对。
- 主按钮按状态显示“开始配对”“再次发起配对”“重新检测”等真实动作；完成后不再显示主按钮。

## 保留的上游真实链路

- USB 自动发现 iPhone/iPad
- Lockdown pairing
- RPPairing / CoreDeviceProxy / RSD
- 无线调试
- Developer Mode 检测
- Developer Disk Image 自动挂载
- Pairing 文件生成、加载、保存、验证
- Seal 直接写入

Seal 使用 `SealPairing.mobiledevicepairing` 作为 Documents 收件文件。Seal 会自动导入；手动导入继续作为恢复入口。

## Windows 前置条件

按上游要求使用 Apple 官网 Windows iTunes / Apple Mobile Device 组件提供 usbmuxd 通道。
不再要求用户手工复制 `idevice_id.exe`、`idevicepair.exe`、`ideviceinfo.exe`。

## 上游固定版本

- repository: `jkcoxson/idevice_pair`
- commit: `e3abb341b73a4fbeb96cdfc5e6652687e4bee130`
- version: `0.1.14`
- license: MIT
