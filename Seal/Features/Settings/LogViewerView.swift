import SwiftUI
import UIKit

/// 日志查看页（2026-10-04）：设置 → 支持与关于 → 查看日志。
/// 显示人话层日志，支持导出技术层（分享 Seal-log.txt）。
struct LogViewerView: View {
    @State private var logText = "正在加载日志…"
    @State private var isSharing = false
    @State private var shareURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(logText)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            Divider()
            Button("导出日志") {
                exportLog()
            }
            .sealPrimaryAction()
            .padding(16)
        }
        .navigationTitle("日志")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadLogs()
        }
        .sheet(isPresented: $isSharing) {
            if let url = shareURL {
                ShareSheet(activityItems: [url])
            }
        }
    }

    private func loadLogs() async {
        // 从 Documents 读取镜像文件（SealLogStore 每次 flush 都会写）
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        if let url = logURL,
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            // 只显示最近 200 行，避免卡顿
            let lines = text.components(separatedBy: "\n")
            let recent = lines.suffix(200).joined(separator: "\n")
            await MainActor.run {
                logText = recent
            }
        } else {
            await MainActor.run {
                logText = "暂无日志"
            }
        }
    }

    private func exportLog() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        if let url = docs?.appendingPathComponent("Seal-log.txt"),
           FileManager.default.fileExists(atPath: url.path) {
            shareURL = url
            isSharing = true
        }
    }
}

/// 系统分享面板
private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
