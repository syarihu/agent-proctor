import Foundation
import ItermBridge
import UseCaseSession

/// 閉じられたタブや終了したプロセスの台帳レコードを定期的に整理するウォッチャー
@MainActor
final class Reaper {
    /// 定期クリーンアップ間隔
    private let interval: TimeInterval = 30
    private var timer: Timer?
    private let writer = LedgerWriter()

    init(onChange: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // iTerm2 のセッション一覧取得失敗時（権限未付与など）も、プロセスの生死判定によるクリーンアップを実行できるよう空配列でフォールバックする
                let alive = ItermBridge.liveSessionIDs() ?? []
                // メインスレッドのブロックを防ぐため台帳書き込みはバックグラウンドで行う
                self.writer.submit({
                    !((try? ReapClosedSessions.reap(aliveSessionIDs: alive)) ?? []).isEmpty
                }, changed: onChange)
            }
        }
    }

    deinit { timer?.invalidate() }
}
