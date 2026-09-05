import Foundation
import Model
import RepositoryLedger

/// 要確認（waiting/done/failed）マークを解除する。
/// 通知の取り下げだけでなく、UI 一覧上の状態と通知センターの食い違いを防ぐため台帳レコードも更新する。
public enum ClearAttention {
    /// 単一のセッションの要確認マークを解除する。
    /// - Parameter id: 対象タスクの台帳 ID
    /// - Returns: 台帳を更新した場合は true
    @discardableResult
    public static func clear(id: String) throws -> Bool {
        guard !id.isEmpty else { return false }
        return try clear(ids: [id])
    }

    /// 複数のセッションの要確認マークを解除する。
    /// - Parameter ids: 対象タスクの台帳 ID リスト
    /// - Returns: 台帳を更新した場合は true
    @discardableResult
    public static func clear(ids: [String]) throws -> Bool {
        let targets = Set(ids)
        guard !targets.isEmpty else { return false }

        // 不要なロック取得を防ぐため、対象タスクに変更が必要か事前に確認する
        guard LedgerStore.tasks().contains(where: {
            targets.contains($0.id) && needsClearing($0)
        }) else { return false }

        let now = Int(Date().timeIntervalSince1970)
        try LedgerStore.withLock { ledger in
            for index in ledger.tasks.indices
            where targets.contains(ledger.tasks[index].id)
                && needsClearing(ledger.tasks[index]) {
                clear(&ledger.tasks[index], now: now)
            }
        }
        return true
    }

    /// 解除対象のタスクかどうかを判定する（CollectTasks.awaitingReview の要確認条件と整合）。
    static func needsClearing(_ task: TaskRecord) -> Bool {
        switch task.status {
        case TaskStatus.waiting: return true
        case TaskStatus.done, TaskStatus.failed: return task.seenAt == nil
        default: return false
        }
    }

    private static func clear(_ task: inout TaskRecord, now: Int) {
        guard task.status == TaskStatus.waiting else {
            // done/failed は既読時刻のみ記録し、ステータス自体は保持する（failed を解決済みと誤認させないため）
            task.seenAt = now
            return
        }
        standDown(&task)
        // updatedAt は最終作業時刻を表し一覧のソート基準となるため、解除操作では更新しない（一覧先頭へ跳ね上がるのを防ぐ）
    }

    /// 確認待ち状態を解除する。ユーザーによる手動解除およびアイドル通知（TaskStatus.settled）から共通で呼び出される。
    /// サブエージェントが稼働中の場合は一覧からの消失を防ぐため running に戻し、全サブエージェント完了時に idle に遷移するよう pendingStatus を設定する。
    @discardableResult
    static func standDown(_ task: inout TaskRecord) -> String {
        task.request = nil
        guard hasLiveChildren(task) else {
            task.status = TaskStatus.idle
            return TaskStatus.idle
        }
        task.status = TaskStatus.running
        // サブエージェント終了後に待機状態へ戻るよう設定。既に完了系（done/failed）が設定済みの場合はそちらを優先する。
        if task.pendingStatus == nil { task.pendingStatus = TaskStatus.idle }
        return TaskStatus.running
    }

    /// サブエージェントが実行中かどうかを判定する。
    /// 詳細リスト（subagentRuns）と件数（subagents）の両方を確認する。
    static func hasLiveChildren(_ task: TaskRecord) -> Bool {
        !(task.subagentRuns ?? []).isEmpty || (task.subagents ?? 0) > 0
    }
}
