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

        let now = Int(Date().timeIntervalSince1970)
        return ordered(records).map { record in
            let exists = FileManager.default.fileExists(atPath: record.worktree)
            return CollectedTask(
                record: record,
                repoName: URL(fileURLWithPath: record.repo).lastPathComponent,
                exists: exists,
                // 動いていた場所を手で消された場合。台帳には残っているので消失として見せる
                status: exists ? record.status : TaskStatus.missing,
                diff: exists ? diff(for: record) : DiffCounts(),
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt))
        }
    }

    /// 台帳から来る値だけを差し替える。**git を起動しない**。
    ///
    /// 状態や「いま触っているツール」はツールのたびに変わるので、差分を
    /// 数え直すまで出せないと後追いになる。差分と worktree の有無は前回の値を
    /// そのまま使い、数え直しは呼ぶ側の都合 (間隔・状態の変化) で回す。
    ///
    /// 顔ぶれ (ID) が変わっていたら前回の値を当てられないので nil を返す。
    /// 呼ぶ側はそのとき数え直す。
    public static func reapplied(_ tasks: [CollectedTask], records: [TaskRecord],
                                 now: Int = Int(Date().timeIntervalSince1970))
        -> [CollectedTask]? {
        guard Set(tasks.map(\.id)) == Set(records.map(\.id)) else { return nil }
        var previous: [String: CollectedTask] = [:]
        for task in tasks { previous[task.id] = task }
        return ordered(records).compactMap { record in
            guard let old = previous[record.id] else { return nil }
            return CollectedTask(
                record: record,
                repoName: old.repoName,
                exists: old.exists,
                status: old.exists ? record.status : TaskStatus.missing,
                diff: old.diff,
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt))
        }
    }

    /// 新しい順。createdAt が同じものは台帳の並びを保つ
    /// (Swift の sorted は安定ではないので添字で決着をつける)
    static func ordered(_ records: [TaskRecord]) -> [TaskRecord] {
        records.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 作業量を数える。
    ///
    /// 見たいのは「そのエージェントが今やった分」なので HEAD からの差分、
    /// つまり未コミットの変更だけを数える。ベースブランチから数えると、
    /// もともと積まれていたコミットの歴史がまるごと出てしまい、
    /// 今の作業量が分からなくなる。
    ///
    /// 新規ファイルは git diff に出ないため untracked として別に数える。
    /// エージェントの成果はファイル追加であることが多く、ここが漏れると
    /// 「何もしていない」ように見えてしまう。
    public static func diff(for record: TaskRecord) -> DiffCounts {
        let lines = GitClient.changedLines(record.worktree, since: "HEAD")
        return DiffCounts(
            added: lines.added,
            removed: lines.removed,
            untracked: GitClient.untrackedFiles(record.worktree).count)
    }
}
