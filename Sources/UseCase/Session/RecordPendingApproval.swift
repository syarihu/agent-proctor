import Foundation
import Model
import RepositoryLedger
import Utility

/// Antigravity (agy) が許可を待って止まっているセッションに、手を挙げさせる。
///
/// **これは proctor が肩代わりしている合図。** 他のエージェントでは
/// 「待たせている」はフックが運んでくる (Claude Code の `Notification` など) が、
/// Antigravity にはその口が無い —— 挙げる合図も降ろす合図も飛んでこない
/// (理由は `AntigravityMetadataReader.isAwaitingApproval`)。
/// なので向こうが書いている会話の記録を覗いて、代わりにここで書く。
///
/// **台帳に書くのが肝。** 表示のときに被せる形にすると、一覧・メニューバーの数・
/// macOS の通知・`proctor ls` の4つに同じ判断を写すことになる。
/// 台帳を直せば、その4つはどれも今までどおり動く。
public enum RecordPendingApproval {
    /// 台帳の agy セッションを見て回り、必要なら状態を書き換える。
    ///
    /// **会話の記録を読むのはロックの外。** ロックを握ったまま I/O をすると、
    /// 台帳に触る全員 (フックも含む) を待たせることになる
    /// (`HookPayload.resolvingAntigravitySubagent` と同じ約束)。
    ///
    /// - Returns: 書き換えたら true
    @discardableResult
    public static func record() throws -> Bool {
        // 挙げる相手と降ろす相手を先に決める。ここまでは台帳を読むだけ
        var raise: Set<String> = []
        var lower: Set<String> = []
        for task in LedgerStore.tasks() where task.agent == AgentKind.antigravity {
            guard let conversation = task.sessionId, !conversation.isEmpty else { continue }
            // **読めなかった (nil) ときはどちらにも入れない。** 挙げ損ねた手は
            // 次に確かめたときに挙がるが、勝手に降ろした手は権限確認が出たまま
            // 消えてしまい、人が次に台帳を動かすまで戻らない
            // (理由は `AntigravityMetadataReader.isAwaitingApproval`)
            let waiting = AntigravityMetadataReader.isAwaitingApproval(
                conversationID: conversation)
            switch task.status {
            case TaskStatus.running, TaskStatus.idle:
                if waiting == true { raise.insert(task.id) }
            case TaskStatus.waiting:
                if waiting == false { lower.insert(task.id) }
            default:
                // 終わった・落ちた・消えたものからは挙げない。Stop のあとに残っている
                // 手は片付け損ねであって、いま人を待たせているわけではない。
                // ✅ の上に ⏳ を出すと、どちらが本当か読めなくなる
                continue
            }
        }

        // 何も動かないならロックを取らない (`ClearAttention.clear` と同じ考え方)。
        // ここは数秒ごとに通る道なので、素通りできる回を素通りさせないと、
        // 誰も待たせていない間ずっと台帳の奪い合いに加わることになる
        guard !raise.isEmpty || !lower.isEmpty else { return false }

        let now = Int(Date().timeIntervalSince1970)
        var changed = false
        try LedgerStore.withLock { ledger in
            for index in ledger.tasks.indices {
                let id = ledger.tasks[index].id
                // **状態はロックの中で確かめ直す。** 読んでから書くまでの間に
                // フックが同じ行を触っていることがある (承認した直後の PostToolUse など)。
                // 見たときのまま書くと、既に動き出した行を確認待ちへ引き戻す
                if raise.contains(id), isRaisable(ledger.tasks[index].status) {
                    ledger.tasks[index].status = TaskStatus.waiting
                    ledger.tasks[index].updatedAt = now
                    // また手が挙がったのだから「確認した」は無かったことにする
                    // (`RecordHookEvent` が確認待ちを書くときと揃える)
                    ledger.tasks[index].seenAt = nil
                    ledger.tasks[index].openedAt = nil
                    changed = true
                } else if lower.contains(id),
                          ledger.tasks[index].status == TaskStatus.waiting {
                    // **降ろす口は人が ✓ を押したときと同じところを通す。**
                    // ここに別の降ろし方を書くと、片方だけ直したときに
                    // 「押しても消えない行」ができる
                    ClearAttention.standDown(&ledger.tasks[index])
                    changed = true
                }
            }
        }
        return changed
    }

    /// そこから手を挙げてよい状態か。
    ///
    /// 待機 (idle) も入れてあるのは、**フックを1つも繋いでいない相手にも効かせる**ため。
    /// 降ろすときに通る `ClearAttention.standDown` は待機に落とすので、
    /// 実行中しか見ないと、一度降ろした行は次にフックが来るまで二度と挙がらない。
    /// 繋いでいる人なら PostToolUse がすぐ実行中に戻すので、どのみち通り道は同じ
    private static func isRaisable(_ status: String) -> Bool {
        status == TaskStatus.running || status == TaskStatus.idle
    }
}
