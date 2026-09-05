import AppState
import Combine
import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import UseCaseSession

/// Antigravity (agy) の承認待ち状態を監視するウォッチャー。
/// Antigravity はツール承認要求時にフックを発火しないため、会話ログディレクトリ（FSEvents）の変更を検知して状態（waiting）を台帳に反映する。
@MainActor
final class ApprovalWatcher {
    /// FSEvents 変更フラグのポーリング間隔
    private let pollInterval: TimeInterval = 1
    /// イベント取りこぼし防止のための定期チェック間隔
    private let sweepInterval: TimeInterval = 60

    private let onChange: () -> Void
    private let watcher = WorktreeWatcher()
    private let writer = LedgerWriter()

    private var timer: Timer?
    private var lastSweep = Date.distantPast
    private var cancellable: AnyCancellable?

    init(store: TaskStore, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // 購読開始時の初期値で監視対象を設定する
        cancellable = store.$records.sink { [weak self] records in
            self?.follow(records)
        }
    }

    deinit { timer?.invalidate() }

    /// セッション一覧に基づき Antigravity セッションが存在する場合のみ監視を開始する
    private func follow(_ records: [TaskRecord]) {
        let hasAntigravity = records.contains {
            $0.agent == AgentKind.antigravity && !($0.sessionId ?? "").isEmpty
        }
        guard hasAntigravity else { return standDown() }

        // 同一パスの再登録時は内部でスキップされる
        let place = AntigravityMetadataReader.conversationsDirectory
        watcher.watch([place: place])
        guard timer == nil else { return }
        // 初回起動直後の未検知を防ぐため即時チェック可能にする
        lastSweep = .distantPast
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Antigravity セッションが存在しない場合はリソース節約のため監視タイマーと FSEvents を停止する
    private func standDown() {
        timer?.invalidate()
        timer = nil
        watcher.stop()
    }

    private func tick() {
        let moved = watcher.hasChanged
        let due = Date().timeIntervalSince(lastSweep) >= sweepInterval
        guard moved || due else { return }
        // 次回チェックに向けて変更フラグをリセットする
        _ = watcher.takeChanged()
        lastSweep = Date()
        // メインスレッドのブロックを防ぐためファイル読み込みと台帳書き込みはバックグラウンドで行う
        writer.submit({
            ((try? RecordPendingApproval.record()) ?? false)
        }, changed: onChange)
    }
}
