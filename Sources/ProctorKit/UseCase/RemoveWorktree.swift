import Foundation

/// worktree とブランチを片付ける。
///
/// 戻せない操作なので、確かめられなかったときは進めずに止める。
/// 「git が失敗した」を「変更なし」と読むと、守るための確認が素通りする。
public enum RemoveWorktree {
    public struct Result {
        public var task: TaskRecord
        /// 台帳から外しただけで、worktree には触っていない
        public var recordOnly: Bool
        /// 未マージのためブランチを消せなかった
        public var branchLeftBehind: Bool
    }

    /// - Parameter force: 未コミット・未マージの確認を飛ばして強制的に消す
    public static func run(id: String, force: Bool) throws -> Result {
        try LedgerStore.withLock { ledger in
            let task = try LedgerStore.find(id: id, in: ledger.tasks)

            // 対話セッションの記録は proctor が作ったものではない。
            // worktree はリポジトリ本体そのものなので、消すのは記録だけにする
            if task.isSession {
                ledger.tasks.removeAll { $0.id == task.id }
                return Result(task: task, recordOnly: true, branchLeftBehind: false)
            }

            let exists = FileManager.default.fileExists(atPath: task.worktree)
            if exists && !force { try assertSafeToRemove(task) }

            if exists {
                try GitClient.removeWorktree(task.repo, at: task.worktree, force: force)
            } else {
                GitClient.pruneWorktrees(task.repo)
            }

            var leftBehind = false
            if GitClient.hasLocalBranch(task.repo, task.branch) {
                // git のエラーをそのまま垂れ流すと「片付けました」と矛盾して見えるので、
                // 失敗は呼び出し側が自前の言葉で伝えられるようにする
                leftBehind = !GitClient.deleteBranch(task.repo, task.branch, force: force)
            }

            ledger.tasks.removeAll { $0.id == task.id }
            return Result(task: task, recordOnly: false, branchLeftBehind: leftBehind)
        }
    }

    private static func assertSafeToRemove(_ task: TaskRecord) throws {
        guard let dirty = GitClient.dirtyState(task.worktree) else {
            throw ProctorError(
                "worktree の状態を確認できませんでした。削除する場合は -f を付けてください")
        }
        if dirty {
            throw ProctorError(
                "コミットしていない変更があります。削除する場合は -f を付けてください")
        }

        guard let ahead = GitClient.commitsAhead(task.worktree, base: task.base) else {
            throw ProctorError(
                "origin/\(task.base) と比べられませんでした。削除する場合は -f を付けてください")
        }
        if ahead > 0 {
            throw ProctorError(
                "origin/\(task.base) に入っていないコミットが \(ahead) 件あります。"
                + "削除する場合は -f を付けてください")
        }
    }
}
