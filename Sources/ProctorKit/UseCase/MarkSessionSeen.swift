import Foundation

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
        /// ので、この状態からは外れる) か、人が片付けを押したとき
        /// (`ClearAttention`) の2つだけ
        case untilCleared = "until_cleared"
    }

    /// - Parameters:
    ///   - itermSession: いま見ているタブの guid
    ///   - policy: 未読をいつ降ろすか。**呼ぶ側に決めさせない** ——
    ///     設定の値をそのまま渡してもらい、それが何を意味するかはここで解く
    /// - Returns: 台帳を書き換えたら true
    ///
    /// 対象は終わっているものだけ。動いている最中のタブを見ても、
    /// その時点ではまだ結果が出ていないので確認したことにはならない。
    ///
    /// 失敗にも印を付ける。表示では失敗のまま出す (見たからといって
    /// 片付いたわけではない) が、二度目に気づかせる必要はもう無い。
    @discardableResult
    public static func run(itermSession: String?, policy: Policy) throws -> Bool {
        // 開いても降ろさない設定なら、台帳を読みもしない。
        // ここで止めるので、呼ぶ側 (毎秒叩く FocusWatcher) は設定を渡すだけでよい
        guard policy == .onOpen else { return false }
        guard let session = itermSession, !session.isEmpty else { return false }

        // 変化が無いときにロックを取らないよう、先に読んで確かめる。
        // 同じタブを見続けている間ずっとロックを奪い合っても仕方がない
        let targets = LedgerStore.tasks().filter { needsMark($0, session: session) }
        guard !targets.isEmpty else { return false }

        let now = Int(Date().timeIntervalSince1970)
        try LedgerStore.withLock { ledger in
            for index in ledger.tasks.indices
            where needsMark(ledger.tasks[index], session: session) {
                ledger.tasks[index].seenAt = now
            }
        }
        return true
    }

    private static func needsMark(_ task: TaskRecord, session: String) -> Bool {
        task.itermSession == session
            && (task.status == TaskStatus.done || task.status == TaskStatus.failed)
            && task.seenAt == nil
    }
}
