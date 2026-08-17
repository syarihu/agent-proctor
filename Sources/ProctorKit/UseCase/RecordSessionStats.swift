import Foundation

/// statusline から届く情報を台帳に写す。
///
/// セッション名・モデル・コンテキスト使用率は hooks では取れず、
/// statusline にしか来ない。一覧に出したいので横流ししてもらう。
public enum RecordSessionStats {
    /// statusline は描画のたびに呼ばれるため、内容が変わらないときは書き込まない。
    /// 書くと台帳の更新時刻が動いてサイドバーが無駄に数え直す。
    public static func run(_ payload: HookPayload) throws {
        guard let session = payload.sessionID else { return }

        let name = payload.sessionName
        let model = payload.modelName
        let percent = payload.contextPercent
        let agent = payload.agent
        let rateLimits = payload.rateLimits

        // まだ hooks が登録していないセッションなら何もしない。登録はそちらに任せる。
        // ここで先に読んで確かめるのは、変化が無いときにロックを取らないため
        guard let current = LedgerStore.tasks().first(where: { $0.sessionId == session })
        else { return }
        let agentKey = agent ?? current.agent ?? "claude"
        let ledgerLimits = LedgerStore.agentRateLimits()[agentKey]

        if current.name == name && current.model == model
            && current.contextPercent == percent
            && (agent == nil || current.agent == agent)
            && (rateLimits == nil || (current.rateLimits == rateLimits && ledgerLimits == rateLimits)) { return }

        try LedgerStore.withLock { ledger in
            guard let index = ledger.tasks.firstIndex(where: { $0.sessionId == session })
            else { return }
            ledger.tasks[index].name = name
            ledger.tasks[index].model = model
            ledger.tasks[index].contextPercent = percent
            if let agent { ledger.tasks[index].agent = agent }
            if let rateLimits {
                ledger.tasks[index].rateLimits = rateLimits
                ledger.agentRateLimits[agentKey] = rateLimits
            }
        }
    }
}
