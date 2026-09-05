import Foundation

/// 台帳に記録されるエージェントセッション情報。
/// オプション項目は JSON 出力時にキーを省略し、未設定値とキー欠落を同一視して扱う。
public struct TaskRecord: Codable, Equatable {
    public var id: String
    public var repo: String
    public var branch: String
    /// セッションの作業ディレクトリ（worktree またはリポジトリルート）
    public var worktree: String
    public var sessionId: String?
    public var itermSession: String?
    /// セッションを実行しているエージェントプロセスの PID。
    /// 端末に依存せず生存確認を行うために使用し、iTerm2 以外のセッション終了時にもクリーンアップできるようにする。
    public var pid: Int?
    /// プロセスの起動時刻（epoch 秒）。
    /// macOS の PID 再利用による別プロセスの誤判定を防ぎ、起動時刻が不一致の場合はプロセス終了として扱う。
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
    /// 実行中のツール表示名 ("Edit: TaskStore.swift" など)。
    /// ツール実行のたびに変化するため、経過時間のリセットや並び順の不安定化を防ぐ目的でこの更新では updatedAt を進めない。
    public var activity: String?
    /// 何の承認を待っているか ("Bash: mkdir -p /tmp/x" など)。
    /// 実行中のツール (activity) とはライフサイクルが異なり、承認時にクリアされる。
    public var request: String?
    /// 終了したターンが最後に返したメッセージ (hooks の `last_assistant_message`)。
    /// activity や request とは異なり、完了時に何が行われたかを表示するために保持する。
    public var summary: String?
    /// 完了後、通知等の注意喚起を解除した時刻。
    /// セッションを閲覧した事実 (openedAt) とは別に、通知を再送不要とした判定を管理する。
    public var seenAt: Int?
    /// 完了後、そのタブを閲覧した時刻。
    /// 一覧表示では閲覧済みとして表示しつつ、要確認や通知は未クリアとして残すために seenAt と分離している。
    public var openedAt: Int?
    /// 終了済みサブエージェントの記録 (agent_id → 終了時刻)。
    /// 非同期イベントの遅延到着によって、終了したサブエージェントが再登録されるのを防ぐ。
    public var finishedSubagents: [String: Int]?
    /// 子エージェント待機中に保留している親セッションの完了状態 (done / failed / idle)。
    /// 親のターン完了時にサブエージェントが動作中の場合、すべての子が完了するまで終了処理を遅延させるために保持する。
    public var pendingStatus: String?
    /// 表示用のセッションタイトル。タブのタイトルや明示的な指定名。
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
                summary: String? = nil,
                seenAt: Int? = nil, openedAt: Int? = nil,
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
        self.summary = summary
        self.seenAt = seenAt
        self.openedAt = openedAt
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

    /// 一覧に出す状態。タブを開いたあとの完了は確認済みに畳む
    public var displayStatus: String {
        TaskStatus.display(status: status, seenAt: seenAt, openedAt: openedAt)
    }

    /// 要確認と通知に出す状態。閲覧しただけでは畳まない (`TaskStatus.attention`)。
    public var attentionStatus: String {
        TaskStatus.attention(status: status, seenAt: seenAt)
    }

    /// 表示に使う見出し。人が付けた名前を優先し、無ければセッション名、最後に ID。
    public var displayName: String { title ?? name ?? id }
}

/// 差分の集計。新規ファイルは git diff に含まれないため別途カウントする。
public struct DiffCounts: Codable, Equatable {
    public var added: Int
    public var removed: Int
    public var untracked: Int
    /// 行数でカウントできないバイナリファイルの変更数。
    public var binary: Int
    /// 変更があったファイルの総数。変更の有無判定に使用する。
    public var changedFiles: Int

    public init(added: Int = 0, removed: Int = 0, untracked: Int = 0,
                binary: Int = 0, changedFiles: Int = 0) {
        self.added = added
        self.removed = removed
        self.untracked = untracked
        self.binary = binary
        self.changedFiles = changedFiles
    }

    /// 変更が存在しないかどうか。
    /// リネームやモード変更等の行数が出ない差分も changedFiles に反映されるため、
    /// changedFiles と untracked の2値で判定する。
    public var isEmpty: Bool { changedFiles == 0 && untracked == 0 }
}
