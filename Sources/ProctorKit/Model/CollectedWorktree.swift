import Foundation

/// worktree 1つを表示向けに整えたもの。
///
/// 台帳が知っているのはセッションだけで、worktree は git に聞かないと分からない。
/// セッションが終わっても worktree は残るので、この2つは別物として数える。
///
/// 判断 (片付けてよさそうか) は CollectWorktrees が済ませてある。
/// CLI もサイドバーもこれを整形するだけにする。
public struct CollectedWorktree: Encodable, Identifiable, Equatable {
    /// 場所そのものを鍵にする。worktree に他の識別子は無い
    public var id: String { path }
    public var path: String
    /// 見出しに出す名前 (パスの末尾)
    public var name: String
    /// リポジトリ本体 (メイン worktree) の場所。どのまとまりに属すかの鍵
    public var repo: String
    /// ブランチ名。detached なら nil
    public var branch: String?
    /// リポジトリ本体そのものか。本体は消せないので片付けの候補から外す
    public var isMain: Bool
    /// ここで動いているセッションのID。空なら誰も使っていない
    public var sessions: [String]
    public var diff: DiffCounts
    /// 差分を最後まで数え切れたか。
    ///
    /// **数えられなかったことを「変更なし」と混ぜない。** 読めない worktree や
    /// 壊れた index でも git は静かに空を返すので、そのまま受けると
    /// 「何も残っていない = 消してよい」に化ける
    public var diffKnown: Bool
    /// 取り込み先のブランチに入っているか。
    /// squash merge では false のままになる (歴史が繋がらないため)
    public var merged: Bool
    /// いちばん新しいコミットの時刻。読めなければ 0
    public var lastCommitAt: Int
    /// 最後のコミットからの時間。「どれだけ放置されているか」の手掛かり
    public var idleSeconds: Int
    public var isLocked: Bool
    public var isPrunable: Bool
    /// ベアリポジトリ本体。作業する場所ではない
    public var isBare: Bool

    /// 片付けてよさそうか。
    ///
    /// **これは「消してよい」ではなく「候補に挙げてよい」。** 取り込み済みで、
    /// 未コミットの変更が無く、誰も使っていないものだけを true にする。
    /// squash merge されたものはここに出てこないので、
    /// これが false でも消せないとは限らない (PR の状態を見る側が補う)。
    ///
    /// **実体を失っているもの (prunable) もここには入れない。** あれは
    /// `git worktree prune` の相手であって、消す前に中を確かめる相手ではない
    public var isRemovable: Bool {
        !isMain && !isBare && !isPrunable && merged
            && diffKnown && diff.isEmpty && sessions.isEmpty && !isLocked
    }

    public init(path: String, name: String, repo: String, branch: String?,
                isMain: Bool, sessions: [String], diff: DiffCounts, diffKnown: Bool,
                merged: Bool, lastCommitAt: Int, idleSeconds: Int,
                isLocked: Bool, isPrunable: Bool, isBare: Bool) {
        self.path = path
        self.name = name
        self.repo = repo
        self.branch = branch
        self.isMain = isMain
        self.sessions = sessions
        self.diff = diff
        self.diffKnown = diffKnown
        self.merged = merged
        self.lastCommitAt = lastCommitAt
        self.idleSeconds = idleSeconds
        self.isLocked = isLocked
        self.isPrunable = isPrunable
        self.isBare = isBare
    }

    /// JSON に出す鍵。読む相手 (skill) が判断に使うので、
    /// 計算で出る isRemovable もここに載せる
    enum CodingKeys: String, CodingKey {
        case path, name, repo, branch, isMain, sessions, diff, diffKnown, merged
        case lastCommitAt, idleSeconds, isLocked, isPrunable, isBare, isRemovable
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(path, forKey: .path)
        try box.encode(name, forKey: .name)
        try box.encode(repo, forKey: .repo)
        try box.encodeIfPresent(branch, forKey: .branch)
        try box.encode(isMain, forKey: .isMain)
        try box.encode(sessions, forKey: .sessions)
        try box.encode(diff, forKey: .diff)
        try box.encode(diffKnown, forKey: .diffKnown)
        try box.encode(merged, forKey: .merged)
        try box.encode(lastCommitAt, forKey: .lastCommitAt)
        try box.encode(idleSeconds, forKey: .idleSeconds)
        try box.encode(isLocked, forKey: .isLocked)
        try box.encode(isPrunable, forKey: .isPrunable)
        try box.encode(isBare, forKey: .isBare)
        try box.encode(isRemovable, forKey: .isRemovable)
    }
}

/// リポジトリ1つぶんの worktree。
public struct CollectedRepoWorktrees: Encodable, Identifiable, Equatable {
    public var id: String { repo }
    /// リポジトリ本体の場所
    public var repo: String
    /// 見出しに出す名前
    public var repoName: String
    /// リポジトリの持ち主 (remote から読んだもの)。引かなければ nil
    public var origin: RepoOrigin?
    public var worktrees: [CollectedWorktree]

    /// セッションが乗っていない worktree。サイドバーが畳んで出す相手。
    ///
    /// 実体を失っているものは入れない。サイドバーの行は押せば開く場所なので、
    /// 無い場所を並べると行き先の無い行になる (CLI の一覧には出る)
    public var idle: [CollectedWorktree] {
        worktrees.filter { !$0.isMain && !$0.isBare && !$0.isPrunable && $0.sessions.isEmpty }
    }

    /// 片付けの候補
    public var removable: [CollectedWorktree] { worktrees.filter(\.isRemovable) }

    public init(repo: String, repoName: String, origin: RepoOrigin?,
                worktrees: [CollectedWorktree]) {
        self.repo = repo
        self.repoName = repoName
        self.origin = origin
        self.worktrees = worktrees
    }
}
