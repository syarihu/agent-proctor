import Foundation
import Model
import RepositoryLedger

/// 一覧から1件外す。
///
/// 掃除はプロセスの生死で自動的に回る (ReapClosedSessions・RecordHookEvent) ので、
/// これは人が「もう見なくていい」と決めたときの入り口になる。
///
/// **消すのは記録だけで、worktree には触らない。** worktree を作らないのと同じ理由で、
/// 片付けるのも proctor を呼ぶ側の仕事にしてある。
///
/// 生きているセッションを外しても止めはしない。次にフックが届いた時点で
/// 知らないセッションとして登録し直されるので、消えたままにはならない。
public enum ForgetTask {
    /// - Parameter id: 台帳のID。前方一致でも引ける (LedgerStore.find と同じ)
    /// - Returns: 外した記録。呼ぶ側が「何を消したか」を伝えられるようにする
    @discardableResult
    public static func run(id: String) throws -> TaskRecord {
        let task = try LedgerStore.find(id: id)
        try LedgerStore.drop(ids: [task.id])
        return task
    }
}
