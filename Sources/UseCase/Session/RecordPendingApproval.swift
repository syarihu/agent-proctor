import Foundation
import Model
import RepositoryLedger
import Utility

/// Antigravity のツール実行許可待ち（waiting）状態を台帳に反映する。
/// Antigravity はツール承認待ちイベントをフック送信しないため、会話ログを定期走査して台帳状態を更新する。
public enum RecordPendingApproval {
    /// 台帳の Antigravity セッションを確認し、必要に応じて承認待ち状態（waiting）の反映または解除を行う。
    /// 会話記録の走査（I/O）は台帳ロックの外で行う。
    /// - Returns: 台帳を書き換えた場合は true
    @discardableResult
    public static func record() throws -> Bool {
        var raise: Set<String> = []
        var lower: Set<String> = []
        for task in LedgerStore.tasks() where task.agent == AgentKind.antigravity {
            guard let conversation = task.sessionId, !conversation.isEmpty else { continue }
            // 判定結果が不明（nil）の場合は誤解除・誤設定を防ぐため変更対象に含めない
            let waiting = AntigravityMetadataReader.isAwaitingApproval(
                conversationID: conversation)
            switch task.status {
            case TaskStatus.running, TaskStatus.idle:
                if waiting == true { raise.insert(task.id) }
            case TaskStatus.waiting:
                if waiting == false { lower.insert(task.id) }
            default:
                continue
            }
        }

        // 状態変更がない場合は不要なファイルロック取得を避ける
        guard !raise.isEmpty || !lower.isEmpty else { return false }

        let now = Int(Date().timeIntervalSince1970)
        var changed = false
        try LedgerStore.withLock { ledger in
            for index in ledger.tasks.indices {
                let id = ledger.tasks[index].id
                // 読み取りからロック取得の間にフックで状態が変更された可能性を考慮し、ロック内で現在の状態を再確認する
                if raise.contains(id), isRaisable(ledger.tasks[index].status) {
                    ledger.tasks[index].status = TaskStatus.waiting
                    ledger.tasks[index].updatedAt = now
                    // 新たな承認待ちが発生したため既読・開覧状態をリセットする
                    ledger.tasks[index].seenAt = nil
                    ledger.tasks[index].openedAt = nil
                    changed = true
                } else if lower.contains(id),
                          ledger.tasks[index].status == TaskStatus.waiting {
                    ClearAttention.standDown(&ledger.tasks[index])
                    changed = true
                }
            }
        }
        return changed
    }

    /// 承認待ちへ遷移可能な状態かどうか（running または idle）
    private static func isRaisable(_ status: String) -> Bool {
        status == TaskStatus.running || status == TaskStatus.idle
    }
}
