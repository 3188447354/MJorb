import Foundation
import Testing
@testable import Seal

/// 安装等待文案的格式化。
///
/// 这个计时是「安装阶段没有进度回报」时用户唯一的「还活着」证据，
/// 格式化错位（比如 75 秒显示成 75:00）会让等待时间看起来离谱，
/// 反而加重「卡死了」的判断。
struct InstallWaitNoteTests {

    @Test
    func formatsElapsedAsMinutesAndSeconds() {
        #expect(InstallWaitNote.elapsedText(0) == "0:00")
        #expect(InstallWaitNote.elapsedText(9) == "0:09")
        #expect(InstallWaitNote.elapsedText(60) == "1:00")
        #expect(InstallWaitNote.elapsedText(75) == "1:15")
        #expect(InstallWaitNote.elapsedText(3_600) == "60:00")
    }

    @Test
    func clampsNegativeElapsed() {
        // 时钟回拨 / 起点晚于当前时刻都不该渲染出 "-1:-5" 这种文案。
        #expect(InstallWaitNote.elapsedText(-1) == "0:00")
        #expect(InstallWaitNote.elapsedText(-90) == "0:00")
    }
}
