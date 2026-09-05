import Foundation
import Model
import RepositoryGit

/// 未コミットの変更差分（行数、未追跡ファイル数）のキャッシュを管理する。
/// 計測結果の生データを保持し、欠損値の扱い（0 埋めするか nil 扱いにするか）は呼び出し元の用途
/// （タスク集計か削除判定用 worktree 集計か）に応じて呼び出し元に委任する。
public enum CountChanges {
    /// git の計測結果。取得失敗時は各フィールドが nil となる。
    public struct Counted {
        public let lines: (added: Int, removed: Int, binary: Int, files: Int)?
        public let untracked: Int?
    }

    public static func count(worktree: String) -> Counted {
        lock.lock()
        if let remembered = cache[worktree] {
            lock.unlock()
            return remembered
        }
        lock.unlock()

        // 並行実行時のブロッキングを防ぐため、git 呼び出し中はロックを解放する
        let counted = Counted(lines: GitClient.changedLines(worktree, since: "HEAD"),
                              untracked: GitClient.untrackedCount(worktree))

        // 一時的なコマンド失敗がキャッシュとして永続化するのを防ぐため、両方成功した場合のみキャッシュする
        guard counted.lines != nil, counted.untracked != nil else { return counted }
        lock.lock()
        cache[worktree] = counted
        lock.unlock()
        return counted
    }

    /// 指定された worktree のキャッシュを無効化する（WorktreeWatcher からの変更通知時に呼び出し）
    public static func invalidate(_ worktrees: Set<String>) {
        guard !worktrees.isEmpty else { return }
        lock.lock()
        for worktree in worktrees { cache.removeValue(forKey: worktree) }
        lock.unlock()
    }

    /// 全キャッシュを破棄する（監視イベントの取りこぼし対策としての定期クリア）
    public static func forgetAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static var cache: [String: Counted] = [:]
    private static let lock = NSLock()
}
