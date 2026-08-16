import Foundation

/// マージ済みの worktree をまとめて片付ける。
///
/// 消すのは戻せない操作なので、何を消すかを先に返して、実行は呼び出し側の
/// 明示的な指示 (`--yes`) を待つ形にしてある。
public enum CleanMergedWorktrees {
    public struct Plan {
        /// マージ済みで、未コミットの変更も無いので片付けられる
        public var removable: [(task: TaskRecord, pullRequest: Int)]
        /// マージ済みだが手を入れたまま置いてある。消すと戻せないので外す
        public var dirty: [TaskRecord]

        public var isEmpty: Bool { removable.isEmpty && dirty.isEmpty }
    }

    /// 何が片付けられるかを調べる。ここでは何も消さない。
    public static func plan(in repo: String) throws -> Plan {
        let tasks = LedgerStore.tasks().filter { $0.repo == repo }
        guard !tasks.isEmpty else { return Plan(removable: [], dirty: []) }

        guard let merged = mergedPullRequests(in: repo) else {
            throw TaskhubError(
                "gh からマージ済み PR を取得できませんでした。gh auth login を確認してください")
        }

        var removable: [(TaskRecord, Int)] = []
        var dirty: [TaskRecord] = []
        for task in tasks {
            guard let number = merged[task.branch] else { continue }
            let exists = FileManager.default.fileExists(atPath: task.worktree)
            // 確かめられなかったときは触らない側に倒す
            if exists, GitClient.dirtyState(task.worktree) != false {
                dirty.append(task)
            } else {
                removable.append((task, number))
            }
        }
        return Plan(removable: removable, dirty: dirty)
    }

    /// 計画のうち removable を実際に片付ける。
    /// 1件失敗しても残りは続ける。まとめての片付けが1つの躓きで止まると面倒なので。
    public static func apply(_ plan: Plan) -> [(task: TaskRecord, error: Error)] {
        var failures: [(TaskRecord, Error)] = []
        for (task, _) in plan.removable {
            do {
                // マージ済みでもローカルには未 push のマージコミット等が残りうるので強制で消す
                _ = try RemoveWorktree.run(id: task.id, force: true)
            } catch {
                failures.append((task, error))
            }
        }
        return failures
    }

    /// gh から見たマージ済み PR のブランチ名 → PR 番号。gh が使えなければ nil。
    private static func mergedPullRequests(in repo: String) -> [String: Int]? {
        guard ProcessRunner.exists("gh") else { return nil }
        let (ok, output) = ProcessRunner.capture(
            ["gh", "pr", "list", "--state", "merged", "--limit", "100",
             "--json", "number,headRefName"],
            cwd: repo)
        guard ok, let data = output.data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }

        var merged: [String: Int] = [:]
        for pr in list {
            if let branch = pr["headRefName"] as? String, let number = pr["number"] as? Int {
                merged[branch] = number
            }
        }
        return merged
    }
}
