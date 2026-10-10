from __future__ import annotations

import pathlib
import shutil
import sys

UPSTREAM_COMMIT = "e3abb341b73a4fbeb96cdfc5e6652687e4bee130"
SEAL_PAIRING_FILE = "SealPairing.mobiledevicepairing"


def replace_once(text: str, old: str, new: str, description: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one upstream match, found {count}")
    return text.replace(old, new, 1)


def insert_after_once(text: str, anchor: str, addition: str, description: str) -> str:
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one upstream match, found {count}")
    return text.replace(anchor, anchor + addition, 1)


def replace_tail_once(text: str, anchor: str, replacement: str, description: str) -> str:
    count = text.count(anchor)
    if count != 1:
        raise RuntimeError(f"{description}: expected exactly one upstream match, found {count}")
    start = text.index(anchor)
    return text[:start] + replacement


def patch_cargo(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    anchor = 'rust-i18n = "3"\n'
    addition = 'raw-window-handle = "0.6.2"\n'
    if addition not in text:
        text = insert_after_once(text, anchor, addition, "raw-window-handle dependency")
    path.write_text(text, encoding="utf-8", newline="\n")



def stage_ui_assets(root: pathlib.Path) -> None:
    source = pathlib.Path(__file__).resolve().parent / "assets"
    target = root / "src" / "seal_assets"
    target.mkdir(parents=True, exist_ok=True)
    required = [
        "seal_icon_ui.rgba",
    ]
    for name in required:
        asset = source / name
        if not asset.exists():
            raise RuntimeError(f"missing Seal pairing UI asset: {asset}")
        shutil.copyfile(asset, target / name)


def patch_main(path: pathlib.Path) -> None:
    text = path.read_text(encoding="utf-8")
    app_anchor = '            supported_apps.insert("Ksign".to_string(), "pairingFile.plist".to_string());\n'
    if text.count(app_anchor) != 2:
        raise RuntimeError(
            f"supported-app anchor drifted: expected 2, found {text.count(app_anchor)}"
        )
    app_replacement = app_anchor + (
        '            supported_apps.insert("Seal".to_string(), '
        f'"{SEAL_PAIRING_FILE}".to_string());\n'
    )
    text = text.replace(app_anchor, app_replacement, 2)

    font_function_end = """    }\n}\n\nfn main() {\n"""
    seal_theme = """    }\n}\n\nconst SEAL_ICON_RGBA: &[u8] = include_bytes!(\"seal_assets/seal_icon_ui.rgba\");\nconst SEAL_ICON_SIZE: [usize; 2] = [160, 160];\nconst IPHONE_MODEL_RGBA: &[u8] = include_bytes!(\"seal_assets/iphone_model.rgba\");\nconst IPHONE_MODEL_SIZE: [usize; 2] = [154, 300];\n\n#[cfg(windows)]\nfn setup_windows_backdrop(cc: &eframe::CreationContext<'_>) {\n    use raw_window_handle::{HasWindowHandle, RawWindowHandle};\n    use std::ffi::c_void;\n\n    #[link(name = \"dwmapi\")]\n    unsafe extern \"system\" {\n        fn DwmSetWindowAttribute(\n            hwnd: *mut c_void,\n            dw_attribute: u32,\n            pv_attribute: *const c_void,\n            cb_attribute: u32,\n        ) -> i32;\n    }\n\n    let Ok(window_handle) = cc.window_handle() else { return; };\n    let RawWindowHandle::Win32(handle) = window_handle.as_raw() else { return; };\n\n    const DWMWA_USE_IMMERSIVE_DARK_MODE: u32 = 20;\n    const DWMWA_WINDOW_CORNER_PREFERENCE: u32 = 33;\n    const DWMWA_SYSTEMBACKDROP_TYPE: u32 = 38;\n    const DWMWCP_ROUND: i32 = 2;\n    const DWMSBT_TRANSIENTWINDOW: i32 = 3;\n\n    let hwnd = handle.hwnd.get() as *mut c_void;\n    let light_mode: i32 = 0;\n    let corner = DWMWCP_ROUND;\n    let backdrop = DWMSBT_TRANSIENTWINDOW;\n    unsafe {\n        let _ = DwmSetWindowAttribute(\n            hwnd,\n            DWMWA_USE_IMMERSIVE_DARK_MODE,\n            &light_mode as *const _ as *const c_void,\n            std::mem::size_of_val(&light_mode) as u32,\n        );\n        let _ = DwmSetWindowAttribute(\n            hwnd,\n            DWMWA_WINDOW_CORNER_PREFERENCE,\n            &corner as *const _ as *const c_void,\n            std::mem::size_of_val(&corner) as u32,\n        );\n        let _ = DwmSetWindowAttribute(\n            hwnd,\n            DWMWA_SYSTEMBACKDROP_TYPE,\n            &backdrop as *const _ as *const c_void,\n            std::mem::size_of_val(&backdrop) as u32,\n        );\n    }\n}\n\n#[cfg(not(windows))]\nfn setup_windows_backdrop(_cc: &eframe::CreationContext<'_>) {}\n\nfn setup_seal_theme(ctx: &egui::Context) {\n    let seal_blue = Color32::from_rgb(0, 122, 255);\n    let seal_blue_soft = Color32::from_rgb(226, 239, 255);\n    let mut visuals = egui::Visuals::light();\n    visuals.panel_fill = Color32::from_rgba_unmultiplied(242, 247, 253, 218);\n    visuals.window_fill = Color32::from_rgba_unmultiplied(255, 255, 255, 226);\n    visuals.extreme_bg_color = Color32::from_rgba_unmultiplied(255, 255, 255, 216);\n    visuals.faint_bg_color = Color32::from_rgba_unmultiplied(255, 255, 255, 150);\n    visuals.selection.bg_fill = seal_blue;\n    visuals.hyperlink_color = seal_blue;\n    visuals.widgets.active.bg_fill = seal_blue;\n    visuals.widgets.active.fg_stroke.color = Color32::WHITE;\n    visuals.widgets.hovered.bg_fill = seal_blue_soft;\n    visuals.widgets.hovered.fg_stroke.color = Color32::from_rgb(0, 94, 204);\n    visuals.widgets.inactive.bg_fill = Color32::from_rgba_unmultiplied(255, 255, 255, 188);\n    visuals.widgets.inactive.weak_bg_fill = Color32::from_rgba_unmultiplied(255, 255, 255, 150);\n    visuals.window_corner_radius = egui::CornerRadius::same(24);\n    visuals.menu_corner_radius = egui::CornerRadius::same(16);\n    visuals.widgets.noninteractive.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.inactive.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.hovered.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.active.corner_radius = egui::CornerRadius::same(14);\n    visuals.widgets.open.corner_radius = egui::CornerRadius::same(14);\n    ctx.set_visuals(visuals);\n\n    let mut style = (*ctx.style()).clone();\n    style.spacing.item_spacing = egui::vec2(10.0, 10.0);\n    style.spacing.button_padding = egui::vec2(16.0, 10.0);\n    ctx.set_style(style);\n}\n\nfn seal_ios_supports_remote_pairing(ios_version: &str) -> Option<bool> {\n    let mut parts = ios_version.split('.');\n    let major: i64 = parts.next()?.trim().parse().ok()?;\n    let minor: i64 = parts.next().unwrap_or(\"0\").trim().parse().unwrap_or(0);\n    Some(major > 17 || (major == 17 && minor >= 4))\n}\n\nfn seal_mode_for_ios(ios_version: &str, default_mode: PairingMode) -> PairingMode {\n    match seal_ios_supports_remote_pairing(ios_version) {\n        Some(true) => PairingMode::RemotePairing,\n        Some(false) => PairingMode::Lockdown,\n        None => default_mode,\n    }\n}\n\n#[cfg(test)]\nmod seal_mode_for_ios_tests {\n    use super::*;\n\n    #[test]\n    fn remote_pairing_needs_ios_17_4() {\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.0\"), Some(false));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.3.1\"), Some(false));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.4\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"17.7.2\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"18.6.2\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"26.7\"), Some(true));\n        assert_eq!(seal_ios_supports_remote_pairing(\"—\"), None);\n        assert_eq!(\n            seal_mode_for_ios(\"17.3.1\", PairingMode::RemotePairing),\n            PairingMode::Lockdown\n        );\n        assert_eq!(\n            seal_mode_for_ios(\"17.4\", PairingMode::Lockdown),\n            PairingMode::RemotePairing\n        );\n        assert_eq!(\n            seal_mode_for_ios(\"—\", PairingMode::RemotePairing),\n            PairingMode::RemotePairing\n        );\n    }\n}\n\nfn main() {\n    rust_i18n::set_locale(\"zh-cn\");\n"""
    # The title bar and executable retain the Seal icon. The earlier phone model
    # was decorative only, so the product UI deliberately ships without it.
    seal_theme = seal_theme.replace(
        'const IPHONE_MODEL_RGBA: &[u8] = include_bytes!("seal_assets/iphone_model.rgba");\n'
        'const IPHONE_MODEL_SIZE: [usize; 2] = [154, 300];\n',
        "",
    )
    text = replace_once(text, font_function_end, seal_theme, "Seal theme injection")

    options_anchor = "    let mut options = eframe::NativeOptions::default();\n"
    options_replacement = """    let mut options = eframe::NativeOptions::default();\n    options.viewport = options\n        .viewport\n        .clone()\n        .with_inner_size([820.0, 700.0])\n        .with_min_inner_size([720.0, 620.0])\n        .with_transparent(true)\n        .with_decorations(false);\n"""
    text = replace_once(text, options_anchor, options_replacement, "native viewport setup")
    text = replace_once(
        text,
        '&format!("idevice pair v{}", env!("CARGO_PKG_VERSION")),\n',
        '"Seal 配对助手",\n',
        "native window title",
    )

    creation_anchor = """        Box::new(|cc| {\n            setup_custom_fonts(&cc.egui_ctx);\n            Ok(Box::new(app))\n        }),\n"""
    creation_replacement = """        Box::new(|cc| {\n            setup_custom_fonts(&cc.egui_ctx);\n            setup_seal_theme(&cc.egui_ctx);\n            setup_windows_backdrop(cc);\n            Ok(Box::new(app))\n        }),\n"""
    text = replace_once(text, creation_anchor, creation_replacement, "Seal visual setup")

    init_anchor = "        show_logs: false,\n"
    init_replacement = "        show_logs: false,\n        pending_seal_install: false,\n        seal_icon_texture: None,\n        seal_issue: None,\n        seal_issue_seen: Vec::new(),\n"
    text = replace_once(text, init_anchor, init_replacement, "pending Seal install init")

    struct_anchor = "    show_logs: bool,\n}"
    struct_replacement = "    show_logs: bool,\n    pending_seal_install: bool,\n    seal_icon_texture: Option<egui::TextureHandle>,\n    seal_issue: Option<SealIssue>,\n    seal_issue_seen: Vec<String>,\n}"
    text = replace_once(text, struct_anchor, struct_replacement, "pending Seal install field")

    reset_anchor = "        self.validation_ip_input.clear();\n"
    reset_replacement = "        self.validation_ip_input.clear();\n        self.pending_seal_install = false;\n        self.seal_issue = None;\n        self.seal_issue_seen.retain(|key| {\n            !key.starts_with(\"pairing\")\n                && !key.starts_with(\"install\")\n                && !key.starts_with(\"handoff\")\n        });\n"
    text = replace_once(text, reset_anchor, reset_replacement, "pending Seal install reset")

    issue_model = pathlib.Path(__file__).with_name("seal_issue_model.rs.txt").read_text(
        encoding="utf-8"
    )
    text = replace_once(
        text,
        "fn main() {\n",
        issue_model + "\nfn main() {\n",
        "Seal error dialog model",
    )

    helper_anchor = """    fn push_pairing_status(&mut self, status: String) {\n        self.pairing_file_message = Some(status);\n    }\n}\n"""
    helper_replacement = """    fn push_pairing_status(&mut self, status: String) {\n        self.pairing_file_message = Some(status);\n    }\n\n    fn ensure_seal_textures(&mut self, ctx: &egui::Context) {
        if self.seal_icon_texture.is_none() {
            let image = egui::ColorImage::from_rgba_unmultiplied(SEAL_ICON_SIZE, SEAL_ICON_RGBA);
            self.seal_icon_texture = Some(ctx.load_texture(
                "seal-icon-ui",
                image,
                egui::TextureOptions::LINEAR,
            ));
        }
    }

    fn install_pairing_file_to_seal_if_ready(&mut self) -> bool {\n        let Some(dev) = self\n            .devices\n            .as_ref()\n            .and_then(|devices| devices.get(&self.selected_device))\n            .cloned()\n        else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"未找到当前 iPhone\".to_string());\n            return false;\n        };\n\n        let Some(pairing_file) = self.pairing_file.as_ref() else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"配对文件尚未生成\".to_string());\n            return false;\n        };\n\n        let bytes = match pairing_file.bytes() {\n            Ok(bytes) => bytes,\n            Err(error) => {\n                self.pending_seal_install = false;\n                self.pairing_file_message = Some(error.to_string());\n                return false;\n            }\n        };\n\n        if self.installed_apps.is_none() {\n            self.pairing_file_message = Some(\"正在检测 Seal…\".to_string());\n            return false;\n        }\n\n        let Some(installed_apps) = self\n            .installed_apps\n            .as_ref()\n            .and_then(|apps| apps.as_ref().ok())\n        else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"无法读取已安装应用\".to_string());\n            return false;\n        };\n\n        let Some(bundle_id) = installed_apps.get(\"Seal\").cloned() else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"未找到已安装的 Seal\".to_string());\n            return false;\n        };\n\n        let Some(path) = self.supported_apps().get(\"Seal\").cloned() else {\n            self.pending_seal_install = false;\n            self.pairing_file_message = Some(\"Seal 写入路径缺失\".to_string());\n            return false;\n        };\n\n        self.pending_seal_install = false;\n        self.install_res.insert(\"Seal\".to_string(), None);\n        self.pairing_file_message = Some(\"正在写入 Seal…\".to_string());\n        self.idevice_sender\n            .send(IdeviceCommands::InstallPairingFile((\n                dev,\n                \"Seal\".to_string(),\n                bundle_id,\n                path,\n                bytes,\n            )))\n            .unwrap();\n        true\n    }\n}\n"""
    text = replace_once(text, helper_anchor, helper_replacement, "Seal auto-install helper")

    pairing_anchor = """                GuiCommands::PairingFile(pairing_file) => match pairing_file {\n                    Ok(p) => {\n                        self.pairing_file = Some(p.clone());\n                        self.pairing_file_message = None;\n                        self.pairing_file_string = match p.display_string() {\n                            Ok(serialized) => Some(serialized),\n                            Err(e) => {\n                                self.pairing_file_message = Some(e.to_string());\n                                None\n                            }\n                        };\n                    }\n                    Err(e) => {\n                        self.pairing_file = None;\n                        self.pairing_file_string = None;\n                        self.pairing_file_message = Some(e.to_string());\n                    }\n                },\n"""
    pairing_replacement = """                GuiCommands::PairingFile(pairing_file) => match pairing_file {\n                    Ok(p) => {\n                        self.pairing_file = Some(p);\n                        self.pairing_file_string = None;\n                        self.pairing_file_message = None;\n                        if self.pending_seal_install {\n                            self.install_pairing_file_to_seal_if_ready();\n                        }\n                    }\n                    Err(e) => {\n                        self.pending_seal_install = false;\n                        self.pairing_file = None;\n                        self.pairing_file_string = None;\n                        self.pairing_file_message = Some(e.to_string());\n                    }\n                },\n"""
    text = replace_once(text, pairing_anchor, pairing_replacement, "secure pairing generation handling")

    apps_anchor = "                GuiCommands::InstalledApps(apps) => self.installed_apps = Some(apps),\n"
    apps_replacement = """                GuiCommands::InstalledApps(apps) => {\n                    self.installed_apps = Some(apps);\n                    if self.pending_seal_install && self.pairing_file.is_some() {\n                        self.install_pairing_file_to_seal_if_ready();\n                    }\n                }\n"""
    text = replace_once(text, apps_anchor, apps_replacement, "pending auto-install after installed apps")

    text = patch_error_dialogs(text)

    ui_anchor = "        egui::CentralPanel::default().show(ctx, |ui| {\n"
    ui_template = pathlib.Path(__file__).with_name("seal_ui_tail.rs.txt").read_text(
        encoding="utf-8"
    )
    if not ui_template.endswith("\n"):
        ui_template += "\n"
    text = replace_tail_once(text, ui_anchor, ui_template, "Seal minimal glass UI replacement")

    path.write_text(text, encoding="utf-8", newline="\n")


def patch_error_dialogs(text: str) -> str:
    """把所有报错来源接到弹窗上：错误只进弹窗，页面不再复述报错内容。"""

    raise_helper_anchor = """    fn push_pairing_status(&mut self, status: String) {
        self.pairing_file_message = Some(status);
    }
"""
    raise_helper_replacement = """    fn push_pairing_status(&mut self, status: String) {
        self.pairing_file_message = Some(status);
    }

    /// 让一条报错以弹窗呈现。同一个问题只弹一次，问题被解决后才允许再次弹出。
    fn seal_raise_issue(&mut self, issue: SealIssue) {
        if self.seal_issue_seen.iter().any(|seen| seen == &issue.key) {
            return;
        }
        self.seal_issue_seen.push(issue.key.clone());
        self.seal_issue = Some(issue);
    }

    /// 某个问题已经解决：允许它下次再次弹窗。
    fn seal_resolve_issue(&mut self, key: &str) {
        self.seal_issue_seen.retain(|seen| seen != key);
    }
"""
    text = replace_once(
        text, raise_helper_anchor, raise_helper_replacement, "Seal error dialog helper"
    )

    # 已安装应用读取失败：无论是否在配对流程里，都要弹窗
    text = replace_once(
        text,
        """                GuiCommands::InstalledApps(apps) => {
                    self.installed_apps = Some(apps);
                    if self.pending_seal_install && self.pairing_file.is_some() {
                        self.install_pairing_file_to_seal_if_ready();
                    }
                }
""",
        """                GuiCommands::InstalledApps(apps) => {
                    let failure = match &apps {
                        Ok(_) => None,
                        Err(error) => Some(seal_issue_apps_unreadable(&format!("{error:?}"))),
                    };
                    self.installed_apps = Some(apps);
                    if self.pending_seal_install && self.pairing_file.is_some() {
                        self.install_pairing_file_to_seal_if_ready();
                    }
                    match failure {
                        Some(issue) => self.seal_raise_issue(issue),
                        None => self.seal_resolve_issue("handoff-apps"),
                    }
                }
""",
        "installed apps failure dialog",
    )

    # 交接阶段（写入 Seal）的每一个失败分支
    text = replace_once(
        text,
        """        else {
            self.pending_seal_install = false;
            self.pairing_file_message = Some("未找到当前 iPhone".to_string());
            return false;
        };""",
        """        else {
            self.pending_seal_install = false;
            self.seal_raise_issue(seal_issue_missing_device());
            self.pairing_file_message = Some("未找到当前 iPhone".to_string());
            return false;
        };""",
        "handoff missing device dialog",
    )
    text = replace_once(
        text,
        """        let Some(pairing_file) = self.pairing_file.as_ref() else {
            self.pending_seal_install = false;
            self.pairing_file_message = Some("配对文件尚未生成".to_string());
            return false;
        };""",
        """        let Some(pairing_file) = self.pairing_file.as_ref() else {
            self.pending_seal_install = false;
            self.seal_raise_issue(seal_issue_no_pairing_file());
            self.pairing_file_message = Some("配对文件尚未生成".to_string());
            return false;
        };""",
        "handoff missing pairing file dialog",
    )
    text = replace_once(
        text,
        """            Err(error) => {
                self.pending_seal_install = false;
                self.pairing_file_message = Some(error.to_string());
                return false;
            }""",
        """            Err(error) => {
                self.pending_seal_install = false;
                self.seal_raise_issue(seal_issue_serialize_failed(&error.to_string()));
                self.pairing_file_message = Some(error.to_string());
                return false;
            }""",
        "handoff serialize failure dialog",
    )
    text = replace_once(
        text,
        """        let Some(installed_apps) = self
            .installed_apps
            .as_ref()
            .and_then(|apps| apps.as_ref().ok())
        else {
            self.pending_seal_install = false;
            self.pairing_file_message = Some("无法读取已安装应用".to_string());
            return false;
        };""",
        """        let installed_apps_error = self
            .installed_apps
            .as_ref()
            .and_then(|apps| apps.as_ref().err())
            .map(|error| error.to_string())
            .unwrap_or_else(|| "设备未返回已安装应用列表".to_string());

        let Some(installed_apps) = self
            .installed_apps
            .as_ref()
            .and_then(|apps| apps.as_ref().ok())
        else {
            self.pending_seal_install = false;
            self.seal_raise_issue(seal_issue_apps_unreadable(&installed_apps_error));
            self.pairing_file_message = Some("无法读取已安装应用".to_string());
            return false;
        };""",
        "handoff installed apps dialog",
    )
    text = replace_once(
        text,
        """        let Some(bundle_id) = installed_apps.get("Seal").cloned() else {
            self.pending_seal_install = false;
            self.pairing_file_message = Some("未找到已安装的 Seal".to_string());
            return false;
        };""",
        """        let Some(bundle_id) = installed_apps.get("Seal").cloned() else {
            self.pending_seal_install = false;
            self.seal_raise_issue(seal_issue_seal_missing());
            self.pairing_file_message = Some("未找到已安装的 Seal".to_string());
            return false;
        };""",
        "handoff missing Seal dialog",
    )
    text = replace_once(
        text,
        """        let Some(path) = self.supported_apps().get("Seal").cloned() else {
            self.pending_seal_install = false;
            self.pairing_file_message = Some("Seal 写入路径缺失".to_string());
            return false;
        };""",
        """        let Some(path) = self.supported_apps().get("Seal").cloned() else {
            self.pending_seal_install = false;
            self.seal_raise_issue(seal_issue_seal_path_missing());
            self.pairing_file_message = Some("Seal 写入路径缺失".to_string());
            return false;
        };""",
        "handoff missing Seal path dialog",
    )

    # 命令通道：usbmuxd / 设备列表 / 环境检查 / 配对 / 写入
    text = replace_once(
        text,
        """                    self.devices_placeholder =
                        format!("{} {install_msg}\\n\\n{idevice_error:#?}", t!("no_usbmuxd"));""",
        """                    self.devices_placeholder =
                        format!("{} {install_msg}\\n\\n{idevice_error:#?}", t!("no_usbmuxd"));
                    let install_hint = install_msg.to_string();
                    let usbmuxd_issue =
                        seal_issue_usbmuxd(&format!("{idevice_error:#?}"), &install_hint);
                    self.seal_raise_issue(usbmuxd_issue);""",
        "usbmuxd error dialog",
    )
    text = replace_once(
        text,
        """                    self.devices_placeholder =
                        t!("get_devices_failure", error = format!("{idevice_error:?}")).to_string();""",
        """                    self.devices_placeholder =
                        t!("get_devices_failure", error = format!("{idevice_error:?}")).to_string();
                    let list_issue = seal_issue_device_list(&format!("{idevice_error:?}"));
                    self.seal_raise_issue(list_issue);""",
        "device list error dialog",
    )
    text = replace_once(
        text,
        """                GuiCommands::EnabledWireless => self.wireless_enabled = Some(Ok(())),""",
        """                GuiCommands::EnabledWireless => {
                    self.wireless_enabled = Some(Ok(()));
                    self.seal_resolve_issue("wireless");
                }""",
        "wireless success resolves dialog",
    )
    text = replace_once(
        text,
        """                GuiCommands::EnableWirelessFailure(idevice_error) => {
                    self.wireless_enabled = Some(Err(idevice_error))
                }""",
        """                GuiCommands::EnableWirelessFailure(idevice_error) => {
                    let issue = seal_issue_wireless(&format!("{idevice_error:?}"));
                    self.wireless_enabled = Some(Err(idevice_error));
                    self.seal_raise_issue(issue);
                }""",
        "wireless failure dialog",
    )
    text = replace_once(
        text,
        """                GuiCommands::DevMode(res) => {
                    self.dev_mode_enabled = Some(res);
                }""",
        """                GuiCommands::DevMode(res) => {
                    match &res {
                        Ok(true) => {
                            self.seal_resolve_issue("devmode-off");
                            self.seal_resolve_issue("devmode-unknown");
                        }
                        Ok(false) => self.seal_raise_issue(seal_issue_dev_mode_off()),
                        Err(error) => {
                            let issue = seal_issue_dev_mode_unknown(&format!("{error:?}"));
                            self.seal_raise_issue(issue);
                        }
                    }
                    self.dev_mode_enabled = Some(res);
                }""",
        "developer mode dialog",
    )
    text = replace_once(
        text,
        """                GuiCommands::MountRes(res) => {
                    self.ddi_mounted = Some(res);
                }""",
        """                GuiCommands::MountRes(res) => {
                    match &res {
                        Ok(()) => self.seal_resolve_issue("ddi"),
                        Err(error) => {
                            let issue = seal_issue_support_files(&format!("{error:?}"));
                            self.seal_raise_issue(issue);
                        }
                    }
                    self.ddi_mounted = Some(res);
                }""",
        "developer support file dialog",
    )
    text = replace_once(
        text,
        """                GuiCommands::Devices(vec) => {
                    self.devices = Some(vec);""",
        """                GuiCommands::Devices(vec) => {
                    self.seal_resolve_issue("usbmuxd");
                    self.seal_resolve_issue("device-list");
                    self.seal_resolve_issue("backend");
                    self.devices = Some(vec);""",
        "device list resolves dialogs",
    )
    text = replace_once(
        text,
        """                    Ok(p) => {
                        self.pairing_file = Some(p);
                        self.pairing_file_string = None;
                        self.pairing_file_message = None;
                        if self.pending_seal_install {
                            self.install_pairing_file_to_seal_if_ready();
                        }
                    }
                    Err(e) => {
                        self.pending_seal_install = false;
                        self.pairing_file = None;
                        self.pairing_file_string = None;
                        self.pairing_file_message = Some(e.to_string());
                    }""",
        """                    Ok(p) => {
                        self.pairing_file = Some(p);
                        self.pairing_file_string = None;
                        self.pairing_file_message = None;
                        self.seal_issue_seen.retain(|key| !key.starts_with("pairing"));
                        if self.pending_seal_install {
                            self.install_pairing_file_to_seal_if_ready();
                        }
                    }
                    Err(e) => {
                        self.pending_seal_install = false;
                        self.pairing_file = None;
                        self.pairing_file_string = None;
                        let issue = seal_issue_pairing_failed(&e.to_string());
                        self.pairing_file_message = Some(e.to_string());
                        self.seal_raise_issue(issue);
                    }""",
        "pairing failure dialog",
    )
    text = replace_once(
        text,
        """                    if let Some(v) = self.install_res.get_mut(&name) {
                        *v = Some(res);
                    }
                    self.pairing_file_message = Some(pairing_file_message);
                }""",
        """                    let failure = match &res {
                        Ok(()) => None,
                        Err(e) => Some(seal_issue_install_failed(&name, &e.to_string())),
                    };
                    if let Some(v) = self.install_res.get_mut(&name) {
                        *v = Some(res);
                    }
                    self.pairing_file_message = Some(pairing_file_message);
                    match failure {
                        Some(issue) => self.seal_raise_issue(issue),
                        None => self.seal_resolve_issue("install-failed"),
                    }
                }""",
        "install failure dialog",
    )
    text = replace_once(
        text,
        """                tokio::sync::mpsc::error::TryRecvError::Disconnected => {
                    self.devices_placeholder = t!("backend_disconnected").to_string();
                    if self.pairing_file_message.is_none() {
                        self.pairing_file_message = Some(t!("backend_disconnected").to_string());
                    }
                }""",
        """                tokio::sync::mpsc::error::TryRecvError::Disconnected => {
                    self.devices_placeholder = t!("backend_disconnected").to_string();
                    if self.pairing_file_message.is_none() {
                        self.pairing_file_message = Some(t!("backend_disconnected").to_string());
                    }
                    self.seal_raise_issue(seal_issue_backend_disconnected());
                }""",
        "backend disconnected dialog",
    )

    # 设备已在 usbmuxd 里、却读不到信息：上游只写日志，这里补上弹窗
    text = replace_once(
        text,
        """                GuiCommands::GetDevicesFailure(idevice_error) => {
                    self.devices_placeholder =
                        t!("get_devices_failure", error = format!("{idevice_error:?}")).to_string();
                    let list_issue = seal_issue_device_list(&format!("{idevice_error:?}"));
                    self.seal_raise_issue(list_issue);
                }
""",
        """                GuiCommands::GetDevicesFailure(idevice_error) => {
                    self.devices_placeholder =
                        t!("get_devices_failure", error = format!("{idevice_error:?}")).to_string();
                    let list_issue = seal_issue_device_list(&format!("{idevice_error:?}"));
                    self.seal_raise_issue(list_issue);
                }
                GuiCommands::DeviceReadFailure(idevice_error) => {
                    let issue = seal_issue_device_read(&format!("{idevice_error:?}"));
                    self.seal_raise_issue(issue);
                }
""",
        "device read failure arm",
    )
    text = replace_once(
        text,
        "    InstallPairingFile((String, Result<(), IdeviceError>)), // name\n}",
        "    InstallPairingFile((String, Result<(), IdeviceError>)), // name\n"
        "    DeviceReadFailure(IdeviceError),\n}",
        "device read failure variant",
    )
    text = replace_once(
        text,
        """                            for dev in devs {
                                let p = dev.to_provider(UsbmuxdAddr::default(), "idevice_pair");
                                let mut lc = match LockdownClient::connect(&p).await {
                                    Ok(l) => l,
                                    Err(e) => {
                                        error!("Failed to connect to lockdown: {e:?}");
                                        continue;
                                    }
                                };
                                let values = match lc.get_value(None, None).await {
                                    Ok(v) => v,
                                    Err(e) => {
                                        error!("Failed to get lockdown values: {e:?}");
                                        continue;
                                    }
                                };""",
        """                            for dev in devs {
                                let p = dev.to_provider(UsbmuxdAddr::default(), "idevice_pair");
                                let mut lc = match LockdownClient::connect(&p).await {
                                    Ok(l) => l,
                                    Err(e) => {
                                        error!("Failed to connect to lockdown: {e:?}");
                                        gui_sender.send(GuiCommands::DeviceReadFailure(e)).unwrap();
                                        continue;
                                    }
                                };
                                let values = match lc.get_value(None, None).await {
                                    Ok(v) => v,
                                    Err(e) => {
                                        error!("Failed to get lockdown values: {e:?}");
                                        gui_sender.send(GuiCommands::DeviceReadFailure(e)).unwrap();
                                        continue;
                                    }
                                };""",
        "device list probe failure dialog",
    )
    text = replace_once(
        text,
        """                                    Some(n) => n.to_string(),
                                    _ => {
                                        continue;
                                    }
                                };""",
        """                                    Some(n) => n.to_string(),
                                    _ => {
                                        gui_sender
                                            .send(GuiCommands::DeviceReadFailure(
                                                IdeviceError::InternalError(
                                                    "设备返回的信息缺少 DeviceName 字段".to_string(),
                                                ),
                                            ))
                                            .unwrap();
                                        continue;
                                    }
                                };""",
        "missing device name dialog",
    )
    text = replace_once(
        text,
        """                    let values = match lc.get_value(None, None).await {
                        Ok(v) => v,
                        Err(e) => {
                            error!("Failed to get lockdown values: {e:?}");
                            continue;
                        }
                    };

                    let values = match values.as_dictionary() {
                        Some(v) => v,
                        None => {
                            error!("Values was not a dictionary");
                            continue;
                        }
                    };""",
        """                    let values = match lc.get_value(None, None).await {
                        Ok(v) => v,
                        Err(e) => {
                            error!("Failed to get lockdown values: {e:?}");
                            gui_sender.send(GuiCommands::DeviceReadFailure(e)).unwrap();
                            continue;
                        }
                    };

                    let values = match values.as_dictionary() {
                        Some(v) => v,
                        None => {
                            error!("Values was not a dictionary");
                            gui_sender
                                .send(GuiCommands::DeviceReadFailure(
                                    IdeviceError::InternalError(
                                        "设备返回的信息不是字典结构".to_string(),
                                    ),
                                ))
                                .unwrap();
                            continue;
                        }
                    };""",
        "device info failure dialog",
    )
    text = replace_once(
        text,
        """                    let mut lc = match LockdownClient::connect(&p).await {
                        Ok(l) => l,
                        Err(e) => {
                            error!("Failed to connect to lockdown: {e:?}");
                            continue;
                        }
                    };""",
        """                    let mut lc = match LockdownClient::connect(&p).await {
                        Ok(l) => l,
                        Err(e) => {
                            error!("Failed to connect to lockdown: {e:?}");
                            gui_sender.send(GuiCommands::DeviceReadFailure(e)).unwrap();
                            continue;
                        }
                    };""",
        "device info connect failure dialog",
    )
    text = replace_once(
        text,
        """                GuiCommands::Validated(res) => match res {
                    Ok(()) => self.validate_res = Some(Ok(())),
                    Err(e) => self.validate_res = Some(Err(e.to_string())),
                },""",
        """                GuiCommands::Validated(res) => {
                    match &res {
                        Ok(()) => self.seal_resolve_issue("validate-failed"),
                        Err(error) => {
                            let issue = seal_issue_validate_failed(&format!("{error:?}"));
                            self.seal_raise_issue(issue);
                        }
                    }
                    self.validate_res = match res {
                        Ok(()) => Some(Ok(())),
                        Err(e) => Some(Err(e.to_string())),
                    };
                }""",
        "pairing validation dialog",
    )

    # mDNS 局域网发现的失败也要弹窗（上游用 expect() 直接 panic）
    text = replace_once(
        text,
        """    let discover_sender = idevice_sender.clone();
    rt.spawn(async move {
        discover::start_discover(discover_sender).await;
    });""",
        """    let discover_sender = idevice_sender.clone();
    let discover_gui_sender = gui_sender.clone();
    rt.spawn(async move {
        discover::start_discover(discover_sender, discover_gui_sender).await;
    });""",
        "discover gui channel wiring",
    )
    text = replace_once(
        text,
        "    DeviceReadFailure(IdeviceError),\n}",
        "    DeviceReadFailure(IdeviceError),\n    MdnsFailure(String),\n}",
        "mdns failure variant",
    )
    text = replace_once(
        text,
        """                GuiCommands::DeviceReadFailure(idevice_error) => {
                    let issue = seal_issue_device_read(&format!("{idevice_error:?}"));
                    self.seal_raise_issue(issue);
                }
""",
        """                GuiCommands::DeviceReadFailure(idevice_error) => {
                    let issue = seal_issue_device_read(&format!("{idevice_error:?}"));
                    self.seal_raise_issue(issue);
                }
                GuiCommands::MdnsFailure(detail) => {
                    let issue = seal_issue_mdns(&detail);
                    self.seal_raise_issue(issue);
                }
""",
        "mdns failure arm",
    )

    return text


def patch_discover(path: pathlib.Path) -> None:
    """移除 mDNS 发现里会 panic 的 expect()，并把起停状态上报给界面弹窗。"""

    text = path.read_text(encoding="utf-8")
    text = replace_once(
        text,
        "use log::{debug, warn};\n",
        "use log::{debug, error, warn};\n",
        "discover error logging import",
    )
    text = replace_once(
        text,
        "use crate::IdeviceCommands;\n",
        "use crate::{GuiCommands, IdeviceCommands};\n",
        "discover gui channel import",
    )
    text = replace_once(
        text,
        """pub async fn start_discover(sender: UnboundedSender<IdeviceCommands>) {
    let service_name = format!("_{}._{}.local", SERVICE_NAME, SERVICE_PROTOCOL);
    println!("Starting mDNS discovery for {} with mdns", service_name);

    let stream = mdns::discover::all(&service_name, Duration::from_secs(1))
        .expect("Unable to start mDNS discover stream")
        .listen();
    pin_mut!(stream);

    while let Some(Ok(response)) = stream.next().await {""",
        """/// 把局域网发现的失败上报到界面。
fn seal_report_mdns(gui_sender: &UnboundedSender<GuiCommands>, detail: String) {
    let _ = gui_sender.send(GuiCommands::MdnsFailure(detail));
}

pub async fn start_discover(
    sender: UnboundedSender<IdeviceCommands>,
    gui_sender: UnboundedSender<GuiCommands>,
) {
    let service_name = format!("_{}._{}.local", SERVICE_NAME, SERVICE_PROTOCOL);
    println!("Starting mDNS discovery for {} with mdns", service_name);

    // 上游这里用 expect()：mDNS 起不来会 panic，release 版没有控制台，等于无声无息地丢掉这条能力。
    let stream = match mdns::discover::all(&service_name, Duration::from_secs(1)) {
        Ok(stream) => stream.listen(),
        Err(error) => {
            error!("Failed to start mDNS discovery: {error:?}");
            seal_report_mdns(&gui_sender, format!("{error:?}"));
            return;
        }
    };
    pin_mut!(stream);

    // 上游写成 while let Some(Ok(..))：流里出现一次错误就静默退出循环，同样没有任何提示。
    loop {
        let response = match stream.next().await {
            Some(Ok(response)) => response,
            Some(Err(error)) => {
                error!("mDNS discovery stream error: {error:?}");
                seal_report_mdns(&gui_sender, format!("{error:?}"));
                return;
            }
            None => return,
        };
""",
        "discover panic removal",
    )
    text = replace_once(
        text,
        """            debug!("Discovered {mac_addr} at {addr}");
            sender
                .send(IdeviceCommands::DiscoveredDevice((
                    addr,
                    mac_addr.to_string(),
                )))
                .unwrap();""",
        """            debug!("Discovered {mac_addr} at {addr}");
            if sender
                .send(IdeviceCommands::DiscoveredDevice((
                    addr,
                    mac_addr.to_string(),
                )))
                .is_err()
            {
                return;
            }""",
        "discover send without panic",
    )
    path.write_text(text, encoding="utf-8", newline="\n")


def patch_locale(path: pathlib.Path, expected: str, replacement: str) -> None:
    text = path.read_text(encoding="utf-8")
    text = replace_once(text, expected, replacement, f"locale {path.name}")
    path.write_text(text, encoding="utf-8", newline="\n")


def verify(root: pathlib.Path) -> None:
    main = (root / "src" / "main.rs").read_text(encoding="utf-8")
    cargo = (root / "Cargo.toml").read_text(encoding="utf-8")
    required = [
        'supported_apps.insert("Seal".to_string(), "SealPairing.mobiledevicepairing".to_string());',
        "fn setup_seal_theme",
        "fn setup_windows_backdrop",
        "DWMSBT_TRANSIENTWINDOW",
        'rust_i18n::set_locale("zh-cn");',
        '"Seal 配对助手"',
        "pending_seal_install",
        "seal_icon_texture",
        "include_bytes!(\"seal_assets/seal_icon_ui.rgba\")",
        "fn ensure_seal_textures",
        "fn install_pairing_file_to_seal_if_ready",
        "开始配对",
        "配对请求未获允许",
        '"完成".to_string()',
        "等待连接",
        "GeneratePairingFile",
        "InstallPairingFile",
        "ValidateRemote",
        "EnableWireless",
        "CheckDevMode",
        "AutoMount",
        "PairingMode::Lockdown",
        "PairingMode::RemotePairing",
        "fn seal_ios_supports_remote_pairing",
        "fn seal_mode_for_ios",
        "seal_lockdown_only",
        "seal_mode_for_ios(&ios_version, self.pairing_mode)",
        "let has_ios_version = ios_version != \"—\";",
        "has_device && has_ios_version && !environment_checking && !is_processing",
        '"开发者模式"',
        '"无线调试"',
        '"开发者支持文件"',
        "正在读取 iOS 版本…",
        "现在可关闭此窗口",
        "fn seal_raise_issue",
        "fn seal_resolve_issue",
        "seal_issue_seen",
        "egui::Modal::new",
        "seal-issue-dialog",
        "SealIssueRetry::Reprime",
        "seal_issue_usbmuxd",
        "seal_issue_device_list",
        "seal_issue_wireless",
        "seal_issue_dev_mode_off",
        "seal_issue_dev_mode_unknown",
        "seal_issue_support_files",
        "seal_issue_backend_disconnected",
        "seal_issue_pairing_failed",
        "seal_issue_install_failed",
        "seal_issue_seal_missing",
        "seal_issue_device_read",
        "seal_issue_validate_failed",
        "seal_issue_mdns",
        "DeviceReadFailure",
        "MdnsFailure",
        "解决办法",
        "知道了",
    ]
    missing = [item for item in required if item not in main]
    if missing:
        raise RuntimeError(f"Seal/upstream feature verification failed: {missing}")

    marker = 'supported_apps.insert("Seal".to_string(), "SealPairing.mobiledevicepairing".to_string());'
    if main.count(marker) != 2:
        raise RuntimeError("Seal must be supported in both pairing modes")
    forbidden = [
        'RichText::new(&pairing_file).monospace()',
        "if let Some(pairing_file) = pairing_file_text",
        "seal_lang_selector",
        "seal_view_logs",
        "seal_pairing_ready",
        "seal_pairing_mode",
        "写入已安装应用",
        "已写入 Seal",
        "生成配对并交给 Seal",
        "✦  生成并写入 Seal",
        "▢  复制",
        "phone_texture",
        "IPHONE_MODEL",
        "iphone_model.rgba",
        "button_rect.center_bottom() + egui::vec2(0.0, 24.0)",
        "Seal 未收到配对文件",
        "notice_rect",
        '"写入失败"',
        '"检测失败"',
        '"检查失败"',
    ]
    present = [item for item in forbidden if item in main]
    if present:
        raise RuntimeError(f"Minimal UI still contains removed surface: {present}")
    if 'raw-window-handle = "0.6.2"' not in cargo:
        raise RuntimeError("Windows backdrop dependency missing")

    discover = (root / "src" / "discover.rs").read_text(encoding="utf-8")
    for item in (
        "use log::{debug, error, warn};",
        "use crate::{GuiCommands, IdeviceCommands};",
        "fn seal_report_mdns(",
        "上报到界面",
        "MdnsFailure",
    ):
        if item not in discover:
            raise RuntimeError(f"discover.rs 未接上弹窗上报: {item}")
    for marker in (
        'expect("Unable to start mDNS discover stream")',
        "while let Some(Ok(response)) = stream.next().await",
    ):
        if marker in discover:
            raise RuntimeError(f"discover.rs 仍保留会 panic / 静默退出的上游写法: {marker}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: patch_upstream.py <idevice_pair checkout>", file=sys.stderr)
        return 2

    root = pathlib.Path(sys.argv[1]).resolve()
    patch_cargo(root / "Cargo.toml")
    stage_ui_assets(root)
    patch_main(root / "src" / "main.rs")
    patch_discover(root / "src" / "discover.rs")
    patch_locale(
        root / "locales" / "zh-cn.toml",
        'app_title = "idevice pair"',
        'app_title = "Seal 配对助手"',
    )
    patch_locale(
        root / "locales" / "en.toml",
        'app_title = "idevice pair"',
        'app_title = "Seal Pairing Assistant"',
    )
    verify(root)
    print(f"Seal product pairing UI v14 overlay applied to idevice_pair {UPSTREAM_COMMIT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
