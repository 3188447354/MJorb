import SwiftUI

/// 安装阶段的等待说明（单签进度页与批量续签抽屉共用）。
///
/// installd 通过 installation_proxy 安装时**不回报进度**：上传结束（1.01 哨兵）之后，
/// 从解压、复制到注册的整段时间里 UI 拿不到任何数值。真机反馈（2026-09-16）把这段
/// 静止读成了「卡死」——单签停在 93%，批量停在「传输中」，「怎么都没反应」。
///
/// 这里做两件事，都是为了让「没反应」和「正在装」可区分：
///   1. 明确说出「此阶段没有进度回报」，用户不会以为是自己网断了或 Seal 崩了；
///   2. 秒级计时，给出「已等待 X:XX」——数字在动就证明进程活着。
///
/// 刻意不编造一个假的百分比进度条：安装耗时与包大小/设备 IO 都相关，
/// 任何线性假设都会在慢设备上「走完却还没装完」，比不给进度更糟。
struct InstallWaitNote: View {
    /// 进入安装阶段的时刻。为 nil 时只显示说明文案（例如回看历史会话）。
    let startedAt: Date?
    var tint: Color = .sealAccent

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(message(at: context.date))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.sealTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
    }

    private func message(at now: Date) -> String {
        guard let startedAt else {
            return "设备正在安装，此阶段没有进度回报，请保持 Seal 在前台"
        }
        let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
        return "设备正在安装，此阶段没有进度回报 · 已等待 \(Self.elapsedText(elapsed))"
    }

    /// 秒数 → `m:ss`。超过一小时也只累加分钟（安装不会那么久，但格式化不该崩）。
    static func elapsedText(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        return String(format: "%d:%02d", safe / 60, safe % 60)
    }
}
