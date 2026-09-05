import Foundation

/// サブエージェント1体を表示向けに整えたもの。
///
/// 経過時間を表示側で数えさせないためにここで持たせる
/// (親の `ageSeconds` / `idleSeconds` と同じ考え方)。
public struct CollectedSubagent: Encodable, Identifiable, Equatable {
    public var id: String
    /// 見出しに出す名前 ("Explore" など)
    public var name: String
    /// 何をさせているか (Task ツールの description)。無いこともある
    public var label: String?
    /// サブエージェントが現在実行中のツール
    public var activity: String?
    /// サブエージェント生成からの経過時間（秒）。値が大きい場合は長時間の調査や処理詰まりの可能性がある
    public var elapsedSeconds: Int

    public init(run: SubagentRun, elapsedSeconds: Int) {
        id = run.id
        name = run.displayName
        label = run.label
        activity = run.activity
        self.elapsedSeconds = elapsedSeconds
    }
}

/// 台帳の1件に、その場で数えた情報を足したもの。
///
/// CLI の表もサイドバーもメニューバーもこれを整形するだけにする。
/// 表示側がここから先を計算しなくていいように、必要なものは揃えてある。
public struct CollectedTask: Encodable, Identifiable, Equatable {
    public var id: String
    public var repo: String
    public var branch: String
    public var worktree: String
    public var sessionId: String?
    public var itermSession: String?
    /// 動いていた場所が消えていれば missing に差し替わる。台帳の値とは限らない
    public var status: String
    public var createdAt: Int
    public var updatedAt: Int
    /// 走っているサブエージェントの数。中身が分かるなら、その件数を正とする
    public var subagents: Int
    /// 走っているサブエージェント1体ずつ。中身を送ってこないエージェントでは空になる
    public var subagentRuns: [CollectedSubagent]
    public var agent: String?
    /// いま触っているツール。台帳の値そのまま (止まったあとも残っている)
    public var activity: String?
    /// 何の承認を待っているか。台帳の値そのまま
    public var request: String?
    /// 終わったターンが最後に言ったこと。台帳の値そのまま
    public var summary: String?
    /// 終わったあと、もう知らせなくていいと決まった時刻
    public var seenAt: Int?
    /// 終わったあと、そのタブを開いて中を見た時刻。
    /// 一覧の行だけがこれを見る (要確認と通知は seenAt のほう)
    public var openedAt: Int?
    /// 人が明示的に付けた名前 (タブのタイトルなど)
    public var title: String?
    public var name: String?
    public var model: String?
    public var contextPercent: Int?
    public var rateLimits: AgentRateLimits?
    public var account: String?

    /// 表示側でパスから切り出さずに済むよう名前にしておく。
    /// プロジェクトごとにまとめるときの見出しになる
    public var repoName: String
    /// リポジトリの持ち主 (remote URL から読んだもの)。
    /// Organization ごとにまとめるときの見出しになる。remote が無ければ nil
    public var origin: RepoOrigin?
    public var exists: Bool
    public var diff: DiffCounts
    public var ageSeconds: Int
    /// 最後に状態が動いてからの時間。実行中のまま長いと、
    /// 考え込んでいるのか止まっているのかの手がかりになる
    public var idleSeconds: Int

    /// 一覧に出す見出し。
    ///
    /// 人が付けた名前 (タブのタイトル) → エージェントが付けたセッション名 → ID の順。
    /// 人が「この作業はこれ」と決めた名前のほうが、会話から起こした要約より当てになる
    public var displayName: String { title ?? name ?? id }

    /// iTerm2 のタブとして開き直せるか。判定は TaskRecord.isItermManaged と同じ。
    ///
    /// 数え上げてから絞りたい側 (アプリ) のために持つ。
    /// 数える前に絞ると、端末外で動いているセッションが worktree 突合から漏れ、
    /// 使用中の作業ツリーが未使用と判定されるため。
    public var isItermManaged: Bool { !(itermSession ?? "").isEmpty }

    /// 一覧に出す状態。タブを開いたあとの完了は確認済みに畳む。
    /// 動いていた場所が消えていれば status のほうが先に missing になっている
    public var displayStatus: String {
        TaskStatus.display(status: status, seenAt: seenAt, openedAt: openedAt)
    }

    /// 要確認と通知に出す状態。閲覧しただけでは畳まない (`TaskStatus.attention`)。
    public var attentionStatus: String {
        TaskStatus.attention(status: status, seenAt: seenAt)
    }

    /// いま出してよい活動。動いているあいだだけ返す。
    /// 止まったあとも出しておくと、終わった作業を今やっているように見える
    public var currentActivity: String? {
        status == TaskStatus.running ? activity : nil
    }

    /// 承認待ちの要求内容。確認待ちの間だけ返す。
    /// 承認後に台帳から消えるまでに1回フックが必要なため、
    /// 状態を確認せずに返すと実行再開後も承認待ち内容が表示され続ける。
    public var currentRequest: String? {
        status == TaskStatus.waiting ? request : nil
    }

    /// ターンの締めメッセージ。完了または失敗時のみ返す。
    /// サブエージェント待ちで保留された done も台帳に載るため、
    /// 状態を確認しないと実行中にも完了時メッセージが表示されてしまう。
    public var currentSummary: String? {
        status == TaskStatus.done || status == TaskStatus.failed ? summary : nil
    }

    /// 現在表示すべきサブエージェント。
    /// 承認待ち中も子エージェントの入力を確認できるよう表示対象に含める。
    /// 親のターン完了後もサブエージェントが台帳に残ることがあるため、
    /// 実行中または確認待ちの状態に絞って表示する。
    public var currentSubagents: [CollectedSubagent] {
        CollectedTask.visibleSubagents(subagentRuns, status: status)
    }

    static func visibleSubagents(_ runs: [CollectedSubagent],
                                 status: String) -> [CollectedSubagent] {
        status == TaskStatus.running || status == TaskStatus.waiting ? runs : []
    }

    /// エージェント種別の解決 ("claude" / "agy" / "codex")
    public var resolvedAgent: String {
        if let agent, !agent.isEmpty { return agent }
        if let model, let guessed = AgentKind.guessed(fromModel: model) { return guessed }
        return AgentKind.claude
    }

    /// アカウントを含むエージェント識別キー ("claude", "claude:work", "agy" など)
    public var resolvedAccountKey: String {
        if let account, !account.isEmpty {
            return "\(resolvedAgent):\(account)"
        }
        return resolvedAgent
    }

    /// 一覧に出すエージェントの表示名
    public var agentDisplayName: String {
        let base = AgentKind.displayName(resolvedAgent)
        if let account, !account.isEmpty {
            return "\(base) (\(account))"
        }
        return base
    }

    public init(record: TaskRecord, repoName: String, origin: RepoOrigin?,
                exists: Bool, status: String,
                diff: DiffCounts, ageSeconds: Int, idleSeconds: Int, now: Int) {
        id = record.id
        repo = record.repo
        branch = record.branch
        worktree = record.worktree
        sessionId = record.sessionId
        itermSession = record.itermSession
        self.status = status
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        subagentRuns = (record.subagentRuns ?? []).map {
            CollectedSubagent(run: $0, elapsedSeconds: max(0, now - $0.startedAt))
        }
        // サブエージェントの実体一覧が取得できている場合はその件数を使用する。
        // （古い連携で PreToolUse で +1 された場合の二重カウントを防ぐため）
        // 表示側で状態に応じたフィルタを行っているため、カウント側も同じ条件で絞り込む。
        subagents = subagentRuns.isEmpty
            ? (record.subagents ?? 0)
            : CollectedTask.visibleSubagents(subagentRuns, status: status).count
        agent = record.agent
        activity = record.activity
        request = record.request
        summary = record.summary
        seenAt = record.seenAt
        openedAt = record.openedAt
        title = record.title
        name = record.name
        model = record.model
        contextPercent = record.contextPercent
        rateLimits = record.rateLimits
        account = record.account
        self.repoName = repoName
        self.origin = origin
        self.exists = exists
        self.diff = diff
        self.ageSeconds = ageSeconds
        self.idleSeconds = idleSeconds
    }
}
