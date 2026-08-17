import Foundation

/// そのタブを見たことにする。
///
/// どのタブを見ているかは iTerm2 にしか無い情報なので、聞きに行くのは
/// アプリ側 (ItermBridge)。ここが持つのは「見たとき何を記録するか」の判断だけ。
public enum MarkSessionSeen {
    /// - Parameter itermSession: いま見ているタブの guid
    /// - Returns: 台帳を書き換えたら true
    ///
    /// 対象は終わっているものだけ。動いている最中のタブを見ても、
    /// その時点ではまだ結果が出ていないので確認したことにはならない。
    ///
    /// 失敗にも印を付ける。表示では失敗のまま出す (見たからといって
    /// 片付いたわけではない) が、二度目に気づかせる必要はもう無い。
    @discardableResult
    public static func run(itermSession: String?) throws -> Bool {
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
