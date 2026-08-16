import Foundation
import Combine
import ProctorKit

/// 台帳を見張って、表示に使うものを配る。
///
/// **View から Repository を直接触らせないための層**でもある。台帳の読み方が
/// 変わっても、直すのはここだけで済むようにしておく。
///
/// 見張りを2段に分けているのは、値段が違うから。
///
///   - 台帳の更新時刻を見るだけ … stat 1回。状態の変化はここに必ず現れるので短く回す
///   - 一覧を数え直す           … worktree ごとに git を起動する。高いので絞る
///
/// さらに、コードを編集しても台帳は変わらない。差分の数字だけは台帳の変化を
/// 待っていても古いままなので、サイドバーが見えている間は定期的に数え直す。
@MainActor
final class TaskStore: ObservableObject {
    /// サイドバーが出ている間だけ更新される、git まで数えた一覧
    @Published private(set) var tasks: [CollectedTask] = []
    /// 台帳そのもの。git を呼ばないので常に持っておける。
    /// メニューの一覧や「開く」の照合はこちらを使う
    @Published private(set) var records: [TaskRecord] = []
    /// メニューバーの要約
    @Published private(set) var summary: [(status: String, count: Int)] = []

    /// 台帳の更新時刻を見に行く間隔。stat を叩くだけなので軽い
    private let pollInterval: TimeInterval = 0.5
    /// 台帳が変わらなくても数え直す間隔。git を起動するのでこちらは長く取る
    private let recountInterval: TimeInterval = 10

    private var pollTimer: Timer?
    private var lastModified: Date?
    private var lastRecount = Date.distantPast
    /// サイドバーが見えていない間は git を起動しない。
    /// 誰も見ていない一覧のためにノートの電池を使いたくない
    private var collecting = false

    init() {
        reloadRecords()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit { pollTimer?.invalidate() }

    /// ID から台帳の1件を引く。View はここを通す
    func record(id: String) -> TaskRecord? {
        records.first { $0.id == id }
    }

    /// サイドバーの表示が切り替わったときに呼ぶ。
    func setCollecting(_ on: Bool) {
        guard collecting != on else { return }
        collecting = on
        if on { recount() }
    }

    /// 台帳が外から変わったかもしれないときに呼ぶ (自分で書き換えた直後など)。
    func refreshNow() {
        reloadRecords()
        if collecting { recount() }
    }

    private func tick() {
        let modified = LedgerStore.lastModified()
        let changed = modified != lastModified
        if changed {
            lastModified = modified
            reloadRecords()
        }
        guard collecting else { return }
        if changed || Date().timeIntervalSince(lastRecount) >= recountInterval {
            recount()
        }
    }

    private func reloadRecords() {
        records = LedgerStore.tasks()
        summary = TaskStatus.counts(records)
    }

    private func recount() {
        lastRecount = Date()
        // git の起動を待つ間 UI を止めない。数え終わったらメインに戻して差し替える
        Task.detached(priority: .utility) {
            let collected = CollectTasks.run(allRepos: true)
            await MainActor.run { self.tasks = collected }
        }
    }
}
