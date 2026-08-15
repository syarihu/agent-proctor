import Foundation

/// 台帳の1件に、その場で数えた情報を足したもの。
///
/// CLI の表もサイドバーもメニューバーもこれを整形するだけにする。
/// 集計をここに閉じ込めることで、表示側にロジックが漏れるのを防ぐ。
public struct CollectedTask: Encodable, Identifiable {
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
}

public enum Collect {
    /// 台帳に動的な情報を足して返す。表示側・サイドバー・JSON 出力の共通の入り口。
    ///
    /// - Parameters:
    ///   - repo: 指定したリポジトリだけに絞る。allRepos が true なら無視される
    ///   - allRepos: 全リポジトリを対象にする
    public static func tasks(repo: String? = nil, allRepos: Bool = false) -> [CollectedTask] {
        var records = Ledger.loadTasks()
        if !allRepos, let repo {
            records = records.filter { $0.repo == repo }
        }

        // 新しい順。createdAt が同じものは台帳の並びを保つ
        // (Swift の sorted は安定ではないので添字で決着をつける)
        let ordered = records.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        let now = Int(Date().timeIntervalSince1970)
        return ordered.map { task in
            let exists = FileManager.default.fileExists(atPath: task.worktree)
            let diff: DiffCounts
            var status = task.status
            if exists {
                diff = Worktree.diffCounts(worktree: task.worktree, base: task.base,
                                           fromHead: task.isSession)
            } else {
                // worktree を手で消された場合。台帳には残っているので消失として見せる
                status = "missing"
                diff = DiffCounts()
            }
            return CollectedTask(
                id: task.id,
                repo: task.repo,
                branch: task.branch,
                worktree: task.worktree,
                base: task.base,
                ticket: task.ticket,
                sessionId: task.sessionId,
                itermSession: task.itermSession,
                pid: task.pid,
                kind: task.kind,
                status: status,
                createdAt: task.createdAt,
                updatedAt: task.updatedAt,
                subagents: task.subagents ?? 0,
                name: task.name,
                model: task.model,
                contextPercent: task.contextPercent,
                repoName: URL(fileURLWithPath: task.repo).lastPathComponent,
                exists: exists,
                diff: diff,
                ageSeconds: max(0, now - task.createdAt),
                idleSeconds: max(0, now - task.updatedAt))
        }
    }
}
