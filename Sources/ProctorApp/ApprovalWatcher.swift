import AppState
import Combine
import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import UseCaseSession

/// agy が許可を待って止まっていないか、向こうが何か書いたときに見に行かせる。
///
/// **これだけは台帳の見張りでは気づけない。** Antigravity は許可確認を出すときに
/// フックを1つも飛ばさないので、待たせ始めても台帳は動かない
/// (理由は `AntigravityMetadataReader.isAwaitingApproval`)。
/// `TaskStore` が見ているのは台帳の更新時刻なので、そこで待っていても永久に来ない。
///
/// **総当たりで叩きに行かない。** 手が挙がるのも降りるのも、必ず向こうが
/// 会話の記録に書いた瞬間なので、そこに乗る。待たせている間は agy が何も
/// 書かないから、こちらも何もしない。
///
///   - 誰を見るか … `TaskStore.records` (台帳は自分では読まない。`NoticeWatcher` と同じ形)
///   - いつ見るか … 会話の置き場が動いたとき (`WorktreeWatcher` = FSEvents)
///   - 保険     … 動きが無くても時々 (見張りの沈黙は「変わっていない」の証にならない)
///
/// **agy が1枚も無ければ、見張りも周期も持たない。**
///
/// `records` に載るのは iTerm2 のタブを持つセッションだけなので、タブの無い agy は
/// 見に行かない (`NoticeWatcher` と同じ線引き。押しても行き先が無いものは知らせない)。
///
/// 「どれを挙げてどれを降ろすか」の判断は `RecordPendingApproval` が持つ。
@MainActor
final class ApprovalWatcher {
    /// 見張りの印を引き取りに行く間隔。
    ///
    /// **ここでは何も読まない。** ロックを取って印が空かどうかを見るだけなので、
    /// 台帳や DB に触るのは本当に動いたときだけになる (`TaskStore.tick` と同じ形)
    private let pollInterval: TimeInterval = 1
    /// 何も動いていなくても確かめる間隔。**取りこぼしに対する保険。**
    ///
    /// FSEvents は合体するし、見張りを張り替えている間の変化は誰にも届かない。
    /// 落ちた1回のせいで ⏳ が出ないまま (あるいは出たまま) 居座るのを防ぐ
    private let sweepInterval: TimeInterval = 60

    private let onChange: () -> Void
    private let watcher = WorktreeWatcher()
    private let writer = LedgerWriter()

    private var timer: Timer?
    private var lastSweep = Date.distantPast
    private var cancellable: AnyCancellable?

    init(store: TaskStore, onChange: @escaping () -> Void) {
        self.onChange = onChange
        // @Published は購読した時点の値も流すので、最初の1回でここまでの顔ぶれが入る
        cancellable = store.$records.sink { [weak self] records in
            self?.follow(records)
        }
    }

    deinit { timer?.invalidate() }

    /// 見張るかどうかを顔ぶれから決める。
    ///
    /// **1枚でも agy が居れば見張る。** どの会話が待っているかまではここで見ない ——
    /// 置き場はひとつなので、誰かが書けばそれで足りる。
    /// 誰が待っているかを決めるのは `RecordPendingApproval`
    private func follow(_ records: [TaskRecord]) {
        let hasAntigravity = records.contains {
            $0.agent == AgentKind.antigravity && !($0.sessionId ?? "").isEmpty
        }
        guard hasAntigravity else { return standDown() }

        // 同じ顔ぶれなら watch は何もしない (向こうがそう決めている)
        let place = AntigravityMetadataReader.conversationsDirectory
        watcher.watch([place: place])
        guard timer == nil else { return }
        // 立ち上がった回は待たせない。開いた agy が既に手を挙げていることがある
        lastSweep = .distantPast
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
    }

    /// agy が1枚も無くなったとき。**見張りも周期も畳む。**
    ///
    /// 台帳に載っていないものの手は挙がりようがないので、
    /// 誰も居ない間まで起きている理由が無い
    private func standDown() {
        timer?.invalidate()
        timer = nil
        watcher.stop()
    }

    private func tick() {
        let moved = watcher.hasChanged
        let due = Date().timeIntervalSince(lastSweep) >= sweepInterval
        guard moved || due else { return }
        // 印は引き取る。残すと、確かめ終わったあとも動いたことになったままになる
        _ = watcher.takeChanged()
        lastSweep = Date()
        // 会話の記録を読むのも台帳を書くのもメインスレッドから外す
        // (理由は LedgerWriter)
        writer.submit({
            ((try? RecordPendingApproval.record()) ?? false)
        }, changed: onChange)
    }
}
