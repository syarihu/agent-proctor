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
    /// セッションを動かしているエージェント本体のプロセスID。
    /// 端末に依存せず生死を確かめられる唯一の手掛かりで、これがあれば
    /// iTerm2 以外で動かしているセッションも閉じた時点で片付けられる
    public var pid: Int?
    /// pid の起動時刻 (epoch 秒)。macOS は pid を使い回すので、
    /// これが違えば「同じ番号の別のプロセス」として死んだ扱いにする
    public var pidStartedAt: Int?
    public var status: String
    public var createdAt: Int
    public var updatedAt: Int
    public var subagents: Int?
    /// 走っているサブエージェントの中身。`agent_id` を送ってくるエージェントだけが持つ。
    ///
    /// `subagents` (数) と併存させているのは、`agent_id` を送らないエージェントが
    /// いるため。数のほうを捨てると、そちらの一覧から 🤖 が消えてしまう
    public var subagentRuns: [SubagentRun]?
    /// セッションを動かしているエージェント ("claude" / "agy" / "codex")。
    /// タブを開き直すとき (attach) にどの CLI を呼ぶかの分岐に使う
    public var agent: String?
    /// いま触っているツール ("Edit: TaskStore.swift" など)。
    /// ツールを叩くたびに変わるので、ここが動いても updatedAt は動かさない
    /// (動かすと「経過」がツールのたびに 0 に戻り、並び順も落ち着かなくなる)
    public var activity: String?
    /// 何の承認を待っているか ("Bash: mkdir -p /tmp/x" など)。
    ///
    /// **activity と別に持つ。** あちらは「もうやったこと」、こちらは
    /// 「まだやっていないこと」で、消えるきっかけも違う (承認して動き出したら
    /// こちらだけが消える)。混ぜると、承認を待っている最中に直前の
    /// ツールが出て、それの承認を待っているように読めてしまう
    public var request: String?
    /// 終わったあと、そのタブを見た時刻。見ていなければ nil。
    /// また動き出したら nil に戻す (次に終わったときは別の結果なので、改めて見てほしい)
    public var seenAt: Int?
    /// 終わった子の墓標 (agent_id → 終わった時刻)。
    ///
    /// hooks は非同期に飛ぶので、`SubagentStop` のあとにその子の `PostToolUse` が
    /// 遅れて届くことがある。素直に受けると**消したはずの子が生え直し**、
    /// その行に対する SubagentStop はもう来ないので、
    /// セッションが永久に実行中のまま一覧に居座る。遅れて来たものを弾くために持つ
    public var finishedSubagents: [String: Int]?
    /// 子を待つあいだ保留している落ち着き先 (done / failed、または idle)。
    ///
    /// 親のターンは子を待たずに終わるので、まだ子が走っているうちに Stop が届く。
    /// そのまま完了にはできないが、捨ててしまうと**最後の子が帰ってきたときに
    /// 終わりを告げる者がいなくなる** (親の Stop と子の SubagentStop は
    /// 非同期に飛ぶので、Stop のほうが先に着くことがある)。ここに預けておく。
    ///
    /// idle が入るのは、確認待ちを降ろしたのに子が走っていたとき
    /// (`ClearAttention.standDown`)。あちらは Stop が来ない相手なので、
    /// 最後の子が帰った時点で落ち着かせるにはここに預けるしかない
    public var pendingStatus: String?
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
                pid: Int? = nil, pidStartedAt: Int? = nil,
                status: String, createdAt: Int, updatedAt: Int,
                subagents: Int? = nil, subagentRuns: [SubagentRun]? = nil,
                agent: String? = nil,
                activity: String? = nil, request: String? = nil,
                seenAt: Int? = nil,
                finishedSubagents: [String: Int]? = nil,
                pendingStatus: String? = nil, title: String? = nil,
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
        self.pid = pid
        self.pidStartedAt = pidStartedAt
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.subagentRuns = subagentRuns
        self.agent = agent
        self.activity = activity
        self.request = request
        self.seenAt = seenAt
        self.finishedSubagents = finishedSubagents
        self.pendingStatus = pendingStatus
        self.title = title
        self.name = name
        self.model = model
        self.contextPercent = contextPercent
        self.rateLimits = rateLimits
        self.account = account
    }

    /// iTerm2 のタブとして開き直せるか。
    ///
    /// guid を持っているものだけが、押したときに元のタブへ戻れる。
    /// 無いものは新しいタブが開くだけで、動いている本体には辿り着けない。
    /// 空文字は「無い」と同じ扱いにする (空同士が一致してしまうため)
    public var isItermManaged: Bool { !(itermSession ?? "").isEmpty }

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
