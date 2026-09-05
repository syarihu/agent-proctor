import Foundation
import Model
import RepositoryLedger

/// 台帳から指定されたセッション記録を削除する。
/// worktree ディレクトリ自体の削除は行わず、台帳のレコードのみを削除する。
/// 稼働中のセッションを削除した場合でも、次回フック受信時に新規セッションとして再登録される。
public enum ForgetTask {
    /// - Parameter id: 台帳のID（前方一致検索対応）
    /// - Returns: 削除されたタスクレコード
    @discardableResult
    public static func forget(id: String) throws -> TaskRecord {
        let task = try LedgerStore.find(id: id)
        try LedgerStore.drop(ids: [task.id])
        return task
    }
}
