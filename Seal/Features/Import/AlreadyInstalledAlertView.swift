import SwiftUI

/// 已安装包再导入时的系统弹窗：替代抽屉，一句话 + 一个按钮。
struct AlreadyInstalledAlertView: View {
    let draft: ImportDraft
    let onDismiss: () -> Void

    @State private var showAlert = true

    var body: some View {
        Color.clear
            .alert("已安装", isPresented: $showAlert) {
                Button("知道了") {
                    onDismiss()
                }
            } message: {
                Text("\(draft.parsedIPA.name) v\(draft.parsedIPA.version) 已安装，无需重复导入")
            }
            .onChange(of: showAlert) { newValue in
                if newValue == false {
                    onDismiss()
                }
            }
    }
}
