import Foundation
import Model
import RepositoryLedger

/// statusline から届くセッション統計（モデル名、コンテキスト使用率、レートリミット等）を台帳に反映する。
public enum RecordSessionStats {
    /// statusline は描画頻度が高いため、内容に変更がない場合はファイル書き込みをスキップする。
    public static func record(_ raw: HookPayload) throws {
        // 親子関係の解決（ログ読み取り）を伴うため、台帳読み込みと解決はロック外で行う。
        // ファイルオープンと JSON パースの回数を最小化するため台帳読み込みは 1 回にまとめる。
        let snapshot = LedgerStore.read()
        let payload = raw.resolvingAntigravitySubagent(in: snapshot)
        guard let session = payload.sessionID else { return }

        let name = payload.sessionName
        let model = payload.modelName
        let percent = payload.contextPercent
        let agent = payload.agent
        let rateLimits = payload.rateLimits
        let account = payload.account
        let agentKey = payload.agentKey

        // まだ hooks が登録していないセッションなら何もしない。登録はそちらに任せる。
        // ここで先に読んで確かめるのは、変化が無いときにロックを取らないため
        guard let current = snapshot.tasks.first(where: { $0.sessionId == session })
        else { return }
        let ledgerLimits = snapshot.agentRateLimits[agentKey]

        if current.name == name && current.model == model
            && current.contextPercent == percent
            && (agent == nil || current.agent == agent)
            && (account == nil || current.account == account)
            && (rateLimits == nil || (current.rateLimits == rateLimits && ledgerLimits == rateLimits)) { return }

        try LedgerStore.withLock { ledger in
            guard let index = ledger.tasks.firstIndex(where: { $0.sessionId == session })
            else { return }
            ledger.tasks[index].name = name
            ledger.tasks[index].model = model
            ledger.tasks[index].contextPercent = percent
            if let agent { ledger.tasks[index].agent = agent }
            if let account { ledger.tasks[index].account = account }
            if let rateLimits {
                ledger.tasks[index].rateLimits = rateLimits
                ledger.agentRateLimits[agentKey] = rateLimits
            }
        }
    }
}
