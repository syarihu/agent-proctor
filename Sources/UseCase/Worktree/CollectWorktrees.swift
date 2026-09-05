import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import UseCaseTask
import Utility

/// 各リポジトリの worktree 一覧と変更差分を集計する。
/// 台帳からセッションが消去された後もディスク上に作業ツリーが残存するため、
/// セッション起点ではなくリポジトリの作業ツリーを走査して状態を集計する。
public enum CollectWorktrees {
    /// - Parameters:
    ///   - repo: 対象リポジトリを限定する場合に指定。allRepos が true の場合は無視される
    ///   - allRepos: 記録されている全リポジトリを走査するかどうか
    ///   - withOrigin: リモートリポジトリ情報（GitHub 等）の解決を行うかどうか
    ///   - countDiff: 未コミット変更の行数集計を行うかどうか。false の場合は diffKnown が false となり、誤削除防止のため isRemovable も false になる
    ///   - tasks: 突合対象のセッション一覧。渡されない場合は内部で CollectTasks を実行する
    ///   - also: 台帳に記録されていないが追加で走査対象に含めるリポジトリパス
    public static func collect(repo: String? = nil, allRepos: Bool = false,
                               withOrigin: Bool = false,
                               countDiff: Bool = true,
                               tasks: [CollectedTask]? = nil,
                               also: [String] = [],
                               now: Int = Int(Date().timeIntervalSince1970))
        -> [CollectedRepoWorktrees] {
        collect(repo: repo, allRepos: allRepos, withOrigin: withOrigin,
                countDiff: countDiff,
                tasks: tasks, repos: nil, also: also, now: now).groups
    }

    /// worktree の集計結果と取得成否（不完全フラグ）を返す。
    ///
    /// - Returns: `incomplete` は git コマンドの失敗等により一部リポジトリの読み取りができなかった場合に true。
    ///   呼び出し元（UI等）は、一時的な失敗による表示の消失を防ぐため前回の結果を保持する判断材料に用いる。
    public static func collect(repo: String? = nil, allRepos: Bool = false,
                               withOrigin: Bool = false,
                               countDiff: Bool = true,
                               tasks: [CollectedTask]? = nil,
                               repos: [String: Int]?,
                               also: [String] = [],
                               now: Int = Int(Date().timeIntervalSince1970))
        -> (groups: [CollectedRepoWorktrees], incomplete: Bool) {
        let sessions = tasks ?? CollectTasks.collect(allRepos: true, countDiff: countDiff)

        // 台帳に記録済みのリポジトリと、現在アクティブなセッションのリポジトリを合算する
        var lastSeen = repos ?? LedgerStore.repos()
        for task in sessions where lastSeen[task.repo] == nil {
            lastSeen[task.repo] = task.updatedAt
        }

        for path in also where lastSeen[path] == nil { lastSeen[path] = 0 }

        var targets = Array(lastSeen.keys)
        if !allRepos, let repo {
            targets = targets.filter { $0 == repo }
            if targets.isEmpty { targets = [repo] }
        }

        // 更新日時の降順。同一時刻の場合は表示順の揺らぎを防ぐためパス名で安定ソートする
        let ordered = targets.sorted {
            let (a, b) = (lastSeen[$0] ?? 0, lastSeen[$1] ?? 0)
            return a != b ? a > b : $0 < $1
        }

        var groups: [CollectedRepoWorktrees] = []
        var incomplete = false
        for path in ordered {
            guard FileManager.default.fileExists(atPath: path) else {
                continue  // ディレクトリ自体が存在しない場合はスキップ
            }
            guard let group = collect(repo: path, sessions: sessions,
                                      withOrigin: withOrigin, countDiff: countDiff,
                                      now: now) else {
                incomplete = true
                continue
            }
            groups.append(group)
        }
        return (groups, incomplete)
    }

    /// リポジトリ1件分の worktree 情報を集計する。git の問い合わせに失敗した場合は nil。
    static func collect(repo: String, sessions: [CollectedTask],
                        withOrigin: Bool, countDiff: Bool,
                        now: Int) -> CollectedRepoWorktrees? {
        let entries = GitClient.worktrees(repo)
        guard !entries.isEmpty else { return nil }

        let base = GitClient.defaultBranch(repo)
        let baseName = base.map { $0.contains("/") ? String($0.split(separator: "/").last!) : $0 }
        let merged = base.map { GitClient.mergedBranches(repo, into: $0) } ?? []

        let collected = entries.enumerated().map { index, entry in
            let isMain = index == 0  // git worktree list は本体リポジトリを先頭に出力する
            let exists = FileManager.default.fileExists(atPath: entry.path)
            let here = sessions.filter { $0.worktree == entry.path }.map(\.id)
            let countable = exists && !entry.isBare
            // countDiff が無効な場合は nil を設定する。0 を渡すと変更なしとみなされて削除候補に誤分類されるのを防ぐ。
            let counted = (countable && countDiff) ? diff(at: entry.path) : nil
            return CollectedWorktree(
                path: entry.path,
                name: URL(fileURLWithPath: entry.path).lastPathComponent,
                repo: repo,
                branch: entry.branch,
                isMain: isMain,
                sessions: here,
                diff: counted ?? DiffCounts(),
                diffKnown: counted != nil,
                merged: isMerged(entry: entry, isMain: isMain,
                                 merged: merged, baseName: baseName),
                lastCommitAt: countable ? GitClient.lastCommitAt(entry.path) : 0,
                idleSeconds: 0,
                isLocked: entry.isLocked,
                isPrunable: entry.isPrunable || !exists,
                isBare: entry.isBare)
        }.map { worktree -> CollectedWorktree in
            var settled = worktree
            settled.idleSeconds = worktree.lastCommitAt > 0
                ? max(0, now - worktree.lastCommitAt) : 0
            return settled
        }

        // 本体リポジトリを先頭に固定し、残りは最終コミット日時の新しい順に整列する
        let sorted = collected.filter(\.isMain)
            + collected.filter { !$0.isMain }.sorted {
                $0.lastCommitAt != $1.lastCommitAt
                    ? $0.lastCommitAt > $1.lastCommitAt : $0.path < $1.path
            }

        return CollectedRepoWorktrees(
            repo: repo,
            repoName: URL(fileURLWithPath: repo).lastPathComponent,
            origin: withOrigin ? ResolveRepoOrigin.resolve(repo: repo) : nil,
            worktrees: sorted)
    }

    /// 対象ブランチがデフォルトブランチにマージ済みかどうかを判定する。
    /// メインリポジトリ自身や、デフォルトブランチと同一のブランチ、detached HEAD は誤判定を防ぐため除外する。
    static func isMerged(entry: GitClient.WorktreeEntry, isMain: Bool,
                         merged: Set<String>, baseName: String?) -> Bool {
        guard !isMain, let branch = entry.branch, !entry.isDetached,
              branch != baseName else { return false }
        return merged.contains(branch)
    }

    /// 未コミットの変更差分を集計する。
    /// 変更行数または未追跡ファイルの取得に失敗した場合は nil を返す（部分的な結果で変更なしと誤認されるのを防ぐ）。
    static func diff(at worktree: String) -> DiffCounts? {
        let counted = CountChanges.count(worktree: worktree)
        guard let lines = counted.lines, let untracked = counted.untracked else { return nil }
        return DiffCounts(added: lines.added, removed: lines.removed,
                          untracked: untracked, binary: lines.binary,
                          changedFiles: lines.files)
    }
}
