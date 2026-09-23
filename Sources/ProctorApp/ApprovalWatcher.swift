import AppState
import Combine
import Foundation
import Model
import RepositoryLedger
import UseCaseSession

/// Antigravity (agy) の承認待ち状態を監視するウォッチャー。
/// Antigravity はツール承認要求時にフックを発火しないため、会話 DB の書き換えを検知して状態（waiting）を台帳に反映する。
@MainActor
final class ApprovalWatcher {
    /// 会話 DB の書き換えを確かめる間隔
    private let pollInterval: TimeInterval = 1
    /// 書き換えが無くても読み直す間隔。
    /// 印が同じでも、読めなかった（nil）回の答えを取り直すために要る
    private let sweepInterval: TimeInterval = 60

    private let onChange: () -> Void
    private let writer = LedgerWriter()

    private var timer: Timer?
    private var lastSweep = Date.distantPast
    /// 見張る会話 ID（親とサブエージェント）
    private var conversations: [String] = []
    /// 最後に読みに行ったときの各会話の書き込みの印
    private var stamps: [String: String] = [:]
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
        conversations = records
            .filter { $0.agent == AgentKind.antigravity && !($0.sessionId ?? "").isEmpty }
            .flatMap { [$0.sessionId ?? ""] + ($0.subagentRuns ?? []).map(\.id) }
        guard !conversations.isEmpty else { return standDown() }
        guard timer == nil else { return }
        // 初回起動直後の未検知を防ぐため即時チェック可能にする
        lastSweep = .distantPast
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// Antigravity セッションが存在しない場合はリソース節約のため監視タイマーを停止する
    private func standDown() {
        timer?.invalidate()
        timer = nil
        stamps = [:]
    }

    private func tick() {
        // stat は会話1つにつき2回で、中身は読まないのでメインスレッドで済ませる
        var current: [String: String] = [:]
        for id in conversations {
            current[id] = AntigravityMetadataReader.writeStamp(conversationID: id) ?? ""
        }
        let moved = current != stamps
        let due = Date().timeIntervalSince(lastSweep) >= sweepInterval
        guard moved || due else { return }
        // メインスレッドのブロックを防ぐためファイル読み込みと台帳書き込みはバックグラウンドで行う
        let accepted = writer.submit({
            ((try? RecordPendingApproval.record()) ?? false)
        }, changed: onChange)
        // 前の読み込みが走行中で断られたときは印を更新しない。
        // 更新すると、その書き換えを読まないまま次の sweep まで見落とす
        guard accepted else { return }
        stamps = current
        lastSweep = Date()
    }
}
