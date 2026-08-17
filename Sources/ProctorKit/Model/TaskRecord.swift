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
    /// いま触っているツール ("Edit: TaskStore.swift" など)。
    /// ツールを叩くたびに変わるので、ここが動いても updatedAt は動かさない
    /// (動かすと「経過」がツールのたびに 0 に戻り、並び順も落ち着かなくなる)
    public var activity: String?
    /// 終わったあと、そのタブを見た時刻。見ていなければ nil。
    /// また動き出したら nil に戻す (次に終わったときは別の結果なので、改めて見てほしい)
    public var seenAt: Int?
    /// 人が明示的に付けた名前 (端末のタブに付けたタイトルなど)。
    /// エージェントが自分で付ける name より、こちらを先に出す
    public var title: String?

    // ここから下は statusline だけが知っている情報。
    // hooks の payload には来ないので RecordSessionStats が横流しする
    public var name: String?
    public var model: String?
    public var contextPercent: Int?
    public var rateLimits: AgentRateLimits?
    /// アカウント名 (例: "work", "personal", nil)
    public var account: String?

    public init(id: String, repo: String, branch: String, worktree: String,
                sessionId: String? = nil, itermSession: String? = nil,
                status: String, createdAt: Int, updatedAt: Int,
                subagents: Int? = nil, agent: String? = nil,
                activity: String? = nil, seenAt: Int? = nil, title: String? = nil,
                name: String? = nil, model: String? = nil,
                contextPercent: Int? = nil,
                rateLimits: AgentRateLimits? = nil,
                account: String? = nil) {
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
        self.activity = activity
        self.seenAt = seenAt
        self.title = title
        self.name = name
        self.model = model
        self.contextPercent = contextPercent
        self.rateLimits = rateLimits
        self.account = account
    }

    /// 表示に使う状態。見たあとの完了は確認済みに畳む
    public var displayStatus: String {
        TaskStatus.display(status: status, seenAt: seenAt)
    }

    /// 表示に使う見出し。人が付けた名前を先に、無ければセッション名、最後に ID。
    /// 数えた一覧 (CollectedTask) と同じ順で選ぶので、メニューと一覧で名前がずれない
    public var displayName: String { title ?? name ?? id }
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
