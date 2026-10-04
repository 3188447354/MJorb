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
        // App 内只显示人话层：过滤掉技术诊断行（[SEAL-XXX-XXX] 代码行、底层诊断等）
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let logURL = docs?.appendingPathComponent("Seal-log.txt")
        if let url = logURL,
           let text = try? String(contentsOf: url, encoding: .utf8),
           !text.isEmpty {
            let lines = text.components(separatedBy: "\n")
            // 人话层：轮次总结块（▶/✓/■/━）+ 简单状态行；过滤技术诊断行
            let humanLines = lines.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 保留轮次总结的可视块
                if trimmed.hasPrefix("▶") || trimmed.hasPrefix("✓")
                    || trimmed.hasPrefix("■") || trimmed.hasPrefix("━") || trimmed.hasPrefix("─") {
                    return true
                }
                // 过滤带技术码的行（[SEAL-XXX-NNN]）
                if trimmed.range(of: #"\[SEAL-[A-Z]+-\d+[a-z]?\]"#, options: .regularExpression) != nil {
                    return false
                }
                // 过滤底层诊断、 localizedDescription 等技术行
                if trimmed.contains("底层诊断") || trimmed.contains("NSURLErrorDomain")
                    || trimmed.contains("diagnostic:") {
                    return false
                }
                // 保留其他简单信息行
                return !trimmed.isEmpty
            }
            let recent = humanLines.suffix(200).joined(separator: "\n")
            await MainActor.run {
                logText = recent.isEmpty ? "暂无日志" : recent
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
