import Foundation
import Model
import RepositoryLedger

/// そのタブを見たことにする。
///
/// どのタブを見ているかは iTerm2 にしか無い情報なので、聞きに行くのは
/// アプリ側 (ItermBridge)。ここが持つのは「見たとき何を記録するか」の判断だけ。
public enum MarkSessionSeen {
    /// 未読をいつ降ろすか。**人が決めること**なので、判断ではなく設定として受け取る。
    ///
    /// 覚えておくのはアプリ側 (NoticeSettings) だが、選択肢そのものは
    /// ここに置く。台帳に印を打つかどうかを決めるのはこの UseCase なので、
    /// 語彙を表示側に持たせると、増やしたときにどちらを直すのか分からなくなる。
    public enum Policy: String, Sendable {
        /// タブを開いた時点で降ろす。
        /// 「見た = 片付けた」でよければ、押す手間が要らないぶんこちらが早い
        case onOpen = "on_open"
        /// 開いただけでは降ろさない。**とりあえず見て、返事は後で**という
        /// 読み方を残すため。ここで降ろすと、開いた拍子に「まだ返していない」
        /// という事実まで消えてしまい、続きをやり忘れたことに気づけない。
        ///
        /// 降りるのは、そのセッションが次に動いたとき (指示を送れば実行中になる
        /// ので、この状態からは外れる) か、人が通知の ✓ を押したとき
        /// (`ClearAttention`) の2つだけ。
        ///
        /// **残るのは要確認と通知だけ。** 一覧の行のほうは開いた時点で
        /// 静かになる (`openedAt`)。やることリストは要確認に寄せてあるので、
        /// 一覧でまで ✅ を残すと、同じ用事が2か所で待っているように見える
        case untilCleared = "until_cleared"
    }

    /// - Parameters:
    ///   - itermSession: いま見ているタブの guid
    ///   - policy: 未読をいつ降ろすか。**呼ぶ側に解釈させない** ——
    ///     どちらを選ぶかは人が決めることなので、設定の値をそのまま渡してもらい、
    ///     それが何を意味するか (どの印を打つのか) はここで解く
    /// - Returns: 台帳を書き換えたら true
    ///
    /// **「見た」(openedAt) は設定に関わらず打つ。** 設定で変わるのは
    /// 「もう知らせなくていい」(seenAt) を一緒に打つかどうかだけ。
    /// 開いたという事実そのものは、どちらの設定でも起きたことに変わりがなく、
    /// 一覧の行はこれを見て静かになる。
    ///
    /// 対象は終わっているものだけ。動いている最中のタブを見ても、
    /// その時点ではまだ結果が出ていないので確認したことにはならない。
    ///
    /// 失敗にも印を付ける。表示では失敗のまま出す (見たからといって
    /// 片付いたわけではない) が、二度目に気づかせる必要はもう無い。
    @discardableResult
    public static func mark(itermSession: String?, policy: Policy) throws -> Bool {
        guard let session = itermSession, !session.isEmpty else { return false }

        // 変化が無いときにロックを取らないよう、先に読んで確かめる。
        // 同じタブを見続けている間ずっとロックを奪い合っても仕方がない
        guard LedgerStore.tasks().contains(where: {
            needsMark($0, session: session, policy: policy)
        }) else { return false }

        let now = Int(Date().timeIntervalSince1970)
        try LedgerStore.withLock { ledger in
            for index in ledger.tasks.indices
            where needsMark(ledger.tasks[index], session: session, policy: policy) {
                if ledger.tasks[index].openedAt == nil {
                    ledger.tasks[index].openedAt = now
                }
                // 「見た = 片付けた」の設定のときだけ、知らせるほうも降ろす
                if policy == .onOpen, ledger.tasks[index].seenAt == nil {
                    ledger.tasks[index].seenAt = now
                }
            }
        }
        return true
    }

    private static func needsMark(_ task: TaskRecord, session: String, policy: Policy) -> Bool {
        guard task.itermSession == session,
              task.status == TaskStatus.done || task.status == TaskStatus.failed
        else { return false }
        // 打つものが1つでも残っていれば対象。openedAt だけ付いている状態は
        // 「見たが片付けていない」で、設定を後から変えたときにここへ戻ってくる
        return task.openedAt == nil || (policy == .onOpen && task.seenAt == nil)
    }
}
