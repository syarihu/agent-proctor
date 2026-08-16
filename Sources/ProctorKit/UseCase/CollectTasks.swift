import Foundation

/// 台帳に動的な情報を足して返す。表示側の共通の入り口。
///
/// CLI の表もサイドバーもメニューバーもこの戻り値を整形するだけにする。
/// 集計をここに閉じ込めることで、表示側にロジックが漏れるのを防ぐ。
/// 集計を足したくなったらここに書く。
public enum CollectTasks {
    /// - Parameters:
    ///   - repo: 指定したリポジトリだけに絞る。allRepos が true なら無視される
    ///   - allRepos: 全リポジトリを対象にする
    public static func run(repo: String? = nil, allRepos: Bool = false) -> [CollectedTask] {
        var records = LedgerStore.tasks()
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
        return ordered.map { record in
            let exists = FileManager.default.fileExists(atPath: record.worktree)
            return CollectedTask(
                record: record,
                repoName: URL(fileURLWithPath: record.repo).lastPathComponent,
                exists: exists,
                // worktree を手で消された場合。台帳には残っているので消失として見せる
                status: exists ? record.status : TaskStatus.missing,
                diff: exists ? diff(for: record) : DiffCounts(),
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt))
        }
    }

    /// 作業量を数える。
    ///
    /// 新規ファイルは git diff に出ないため untracked として別に数える。
    /// エージェントの成果はファイル追加であることが多く、ここが漏れると
    /// 「何もしていない」ように見えてしまう。
    ///
    /// 対話セッションは HEAD からの差分、つまり未コミットの変更だけを見る。
    /// proctor が作った worktree はブランチ全体がそのタスクの成果なのでベースから
    /// 数えるが、もともと開いていたセッションでベースから数えると
    /// ブランチの歴史がまるごと出てしまい、今の作業量が分からなくなる。
    public static func diff(for record: TaskRecord) -> DiffCounts {
        let point = record.isSession
            ? "HEAD"
            : GitClient.mergeBase(record.worktree, base: record.base)

        var counts = DiffCounts()
        if !point.isEmpty {
            let lines = GitClient.changedLines(record.worktree, since: point)
            counts.added = lines.added
            counts.removed = lines.removed
        }
        counts.untracked = GitClient.untrackedFiles(record.worktree).count
        return counts
    }
}
