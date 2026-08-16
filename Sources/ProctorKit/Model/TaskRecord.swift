import Foundation

/// 台帳に載る1件。動いているエージェントのセッション1つに対応する。
///
/// 記録を作るのは hooks だけで、proctor が worktree を作ることはない
/// (worktree の用意と後片付けは、これを呼ぶ側の仕事)。
/// だから「実体を持つタスク」と「セッション」を区別する必要がなく、
/// ここにあるのは常に生きているセッションになる。
///
/// 省略可能な項目は書き出すときに落とす (Swift の合成コードは Optional を
/// encodeIfPresent で扱う)。台帳を読む側はどれも `null` と欠落を区別していないので、
/// 無い項目はキーごと出さないほうが素直に読める。
public struct TaskRecord: Codable, Equatable {
    public var id: String
    public var repo: String
    public var branch: String
    /// セッションが動いている場所。worktree のこともリポジトリ本体のこともある
    public var worktree: String
    public var sessionId: String?
    public var itermSession: String?
    public var status: String
    public var createdAt: Int
    public var updatedAt: Int
    public var subagents: Int?
    /// セッションを動かしているエージェント ("claude" や "agy")。
    /// タブを開き直すとき (attach) にどの CLI を呼ぶかの分岐に使う
    public var agent: String?

    // ここから下は statusline だけが知っている情報。
    // hooks の payload には来ないので RecordSessionStats が横流しする
    public var name: String?
    public var model: String?
    public var contextPercent: Int?

    public init(id: String, repo: String, branch: String, worktree: String,
                sessionId: String? = nil, itermSession: String? = nil,
                status: String, createdAt: Int, updatedAt: Int,
                subagents: Int? = nil, agent: String? = nil,
                name: String? = nil, model: String? = nil,
                contextPercent: Int? = nil) {
        self.id = id
        self.repo = repo
        self.branch = branch
        self.worktree = worktree
        self.sessionId = sessionId
        self.itermSession = itermSession
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.agent = agent
        self.name = name
        self.model = model
        self.contextPercent = contextPercent
    }
}

/// 差分の数。新規ファイルは git diff に出ないので別に数える。
public struct DiffCounts: Codable, Equatable {
    public var added: Int
    public var removed: Int
    public var untracked: Int

    public init(added: Int = 0, removed: Int = 0, untracked: Int = 0) {
        self.added = added
        self.removed = removed
        self.untracked = untracked
    }

    public var isEmpty: Bool { added == 0 && removed == 0 && untracked == 0 }
}
