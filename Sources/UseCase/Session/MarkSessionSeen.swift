import Foundation
import Model
import RepositoryLedger

/// iTerm2 で対象セッションのタブが閲覧された際の既読状態を記録する。
public enum MarkSessionSeen {
    /// 既読ポリシー設定。
    public enum Policy: String, Sendable {
        /// タブを開いた時点で通知と要確認マークを解除する
        case onOpen = "on_open"
        /// タブを開いただけでは要確認・通知を維持し、ユーザーによる明示的な解除（✓ ボタン）または次の指示送信まで保持する
        case untilCleared = "until_cleared"
    }

    /// - Parameters:
    ///   - itermSession: 閲覧中のタブのセッション GUID
    ///   - policy: 既読ポリシー（onOpen または untilCleared）
    /// - Returns: 台帳を更新した場合は true
    ///
    /// 開覧事実（openedAt）はポリシーに関わらず記録する。
    /// 通知・要確認解除（seenAt）は policy が .onOpen の場合のみ記録する。
    /// 対象は完了（done）または失敗（failed）のセッションのみとする。
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
