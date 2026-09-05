import Foundation
import ItermBridge
import UseCaseSession

/// 定期的に、閉じられたタブの記録を片付けさせる。
///
/// 「どれを消してよいか」の判断は ReapClosedSessions が持つ。
/// ここは iTerm2 という情報源から生きているIDを取ってきて渡すだけ。
@MainActor
final class Reaper {
    /// 反応が遅れても困らないので長めに取る
    private let interval: TimeInterval = 30
    private var timer: Timer?
    private let writer = LedgerWriter()

    init(onChange: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // nil は「分からなかった」であって「1つも無い」ではない。
                // 空の集合として渡すと、向こうは端末との突き合わせだけを見送り、
                // プロセスで生死が分かるものは片付けてくれる。
                // iTerm2 が居なくても・許可が下りていなくても掃除が止まらないよう、
                // ここで諦めてしまわない
                let alive = ItermBridge.liveSessionIDs() ?? []
                // 片付けは台帳を書くのでメインスレッドから外す (理由は LedgerWriter)
                self.writer.submit({
                    !((try? ReapClosedSessions.run(aliveSessionIDs: alive)) ?? []).isEmpty
                }, changed: onChange)
            }
        }
    }

    deinit { timer?.invalidate() }
}
