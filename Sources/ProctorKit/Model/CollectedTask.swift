import Foundation

/// 台帳の1件に、その場で数えた情報を足したもの。
///
/// CLI の表もサイドバーもメニューバーもこれを整形するだけにする。
/// 表示側がここから先を計算しなくていいように、必要なものは揃えてある。
public struct CollectedTask: Encodable, Identifiable, Equatable {
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
    /// worktree が消えていれば missing に差し替わる。台帳の値とは限らない
    public var status: String
    public var createdAt: Int
    public var updatedAt: Int
    public var subagents: Int
    public var name: String?
    public var model: String?
    public var contextPercent: Int?

    /// 表示側でパスから切り出さずに済むよう名前にしておく。
    /// プロジェクトごとにまとめるときの見出しになる
    public var repoName: String
    public var exists: Bool
    public var diff: DiffCounts
    public var ageSeconds: Int
    /// 最後に状態が動いてからの時間。実行中のまま長いと、
    /// 考え込んでいるのか止まっているのかの手がかりになる
    public var idleSeconds: Int

    /// 一覧に出す見出し。セッション名が付いていればそれを、無ければ ID を使う
    public var displayName: String { name ?? id }

    public init(record: TaskRecord, repoName: String, exists: Bool, status: String,
                diff: DiffCounts, ageSeconds: Int, idleSeconds: Int) {
        id = record.id
        repo = record.repo
        branch = record.branch
        worktree = record.worktree
        base = record.base
        ticket = record.ticket
        sessionId = record.sessionId
        itermSession = record.itermSession
        pid = record.pid
        kind = record.kind
        self.status = status
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        subagents = record.subagents ?? 0
        name = record.name
        model = record.model
        contextPercent = record.contextPercent
        self.repoName = repoName
        self.exists = exists
        self.diff = diff
        self.ageSeconds = ageSeconds
        self.idleSeconds = idleSeconds
    }
}
