import Foundation
import ProctorKit

/// 定期的に iTerm2 へ生存を聞いて、閉じられたタブの記録を片付けさせる。
///
/// 「どれを消してよいか」の判断は ReapClosedSessions が持つ。
/// ここは iTerm2 という情報源から生きているIDを取ってきて渡すだけ。
@MainActor
final class Reaper {
    /// 反応が遅れても困らないので長めに取る
    private let interval: TimeInterval = 30
    private var timer: Timer?

    init(onChange: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                // nil は「分からなかった」であって「1つも無い」ではない。
                // 取れなかったときに全部消してしまわないよう、ここで止める
                guard let alive = ItermBridge.liveSessionIDs() else { return }
                let dropped = (try? ReapClosedSessions.run(aliveSessionIDs: alive)) ?? []
                if !dropped.isEmpty { onChange() }
            }
        }
    }

    deinit { timer?.invalidate() }
}
