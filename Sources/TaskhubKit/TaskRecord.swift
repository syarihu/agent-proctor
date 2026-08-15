import Foundation

/// 台帳に載る1件。
///
/// `kind` は2種類ある。
///   - `manual`  … `taskhub new` が作った worktree。実体を持つので消すまで残る
///   - `session` … hooks が見つけた対話セッション。タブが閉じれば消える
/// この違いが差分の数え方 (Worktree.diffCounts) と後片付けの可否を分ける。
///
/// 省略可能な項目は書き出すときに落とす (Swift の合成コードは Optional を
/// encodeIfPresent で扱う)。台帳を読む側はどれも `null` と欠落を区別していないので、
/// 無い項目はキーごと出さないほうが素直に読める。
public struct TaskRecord: Codable, Equatable {
    public var id: String
    public var repo: String
    public var branch: String
    public var worktree: String
    public var base: String
    public var ticket: String?
    public var sessionId: String?
    public var itermSession: String?
    public var pid: Int?
    public var kind: String?
    public var status: String
    public var createdAt: Int
    public var updatedAt: Int
    public var subagents: Int?

    // ここから下は statusline だけが知っている情報。
    // hooks の payload には来ないので Hooks.recordSessionStats が横流しする
    public var name: String?
    public var model: String?
    public var contextPercent: Int?

    public init(id: String, repo: String, branch: String, worktree: String, base: String,
                ticket: String? = nil, sessionId: String? = nil, itermSession: String? = nil,
                pid: Int? = nil, kind: String? = nil, status: String,
                createdAt: Int, updatedAt: Int, subagents: Int? = nil,
                name: String? = nil, model: String? = nil, contextPercent: Int? = nil) {
        self.id = id
        self.repo = repo
        self.branch = branch
        self.worktree = worktree
        self.base = base
        self.ticket = ticket
        self.sessionId = sessionId
        self.itermSession = itermSession
        self.pid = pid
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.name = name
        self.model = model
        self.contextPercent = contextPercent
    }

    /// hooks が見つけた対話セッションかどうか。
    /// worktree がリポジトリ本体そのものなので、消してよいのは記録だけ。
    public var isSession: Bool { kind == "session" }
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
