import Foundation
import Model
import RepositoryGit
import RepositoryGitHub

/// worktree に紐づく Pull Request 情報を解決・キャッシュ管理する。
/// ネットワークアクセスを伴うため、CollectTasks 等の高頻度な処理からは直接呼ばず、
/// バックグラウンド監視ループ等から呼び出す。
public enum ResolvePullRequest {
    /// worktree に対応する PR 情報を取得する。キャッシュがあればそれを返し、期限切れなら gh コマンドで再取得する。
    /// - Parameters:
    ///   - worktree: 対象の作業ツリーパス
    ///   - origin: リポジトリの origin 情報
    /// - Returns: PullRequestRef。存在しない場合や取得不可の場合は nil
    public static func resolve(worktree: String, origin: RepoOrigin?) -> PullRequestRef? {
        // gh コマンドは GitHub 専用のため、それ以外のホスト（GitLab 等）や gh 未インストール環境では早期 return する
        guard origin?.isGitHub == true, GitHubClient.executable != nil else { return nil }

        // セッション途中の git switch に追従するため、台帳記録ではなく現在のブランチ名を取得する
        let branch = GitClient.currentBranch(worktree)
        // detached HEAD や削除済み worktree の場合は古い PR 番号の残留を防ぐためキャッシュを破棄する
        guard !branch.isEmpty, branch != "HEAD", branch != "-" else {
            forget(worktree)
            return nil
        }

        let remembered = entry(for: worktree)
        // ブランチが切り替わっている場合は前ブランチのキャッシュを適用しない
        let usable = remembered?.branch == branch ? remembered : nil
        if let usable, Date().timeIntervalSince(usable.at) < maxAge(of: usable.ref) {
            return usable.ref
        }
        // ネットワーク障害や認証切れ時の無駄なプロセス起動を抑えるため、失敗直後はクールダウンする
        guard !isCoolingDown(worktree) else { return usable?.ref }

        let looked = GitHubClient.pullRequest(worktree: worktree, branch: branch)
        // gh コマンド実行（約0.7秒）の間にブランチが切り替わっていないか再確認し、別ブランチの PR 情報の誤適用を防ぐ
        let settled = GitClient.currentBranch(worktree)
        guard settled == branch else {
            let current = entry(for: worktree)
            return current?.branch == settled ? current?.ref : nil
        }

        switch looked {
        case .found(let ref):
            remember(worktree, branch: branch, ref: ref)
            return ref
        case .absent:
            // PR 未作成ブランチへの頻繁な gh 呼び出しを防ぐため、「存在しない」結果もキャッシュする
            remember(worktree, branch: branch, ref: nil)
            return nil
        case .unavailable:
            noteFailure(worktree)
            // 一時的なコマンド失敗時は「PR なし」と誤認させないため失敗のみ記録し、以前の有効な値があればそれを維持する
            return usable?.ref
        }
    }

    /// 「PR なし」と記録されたキャッシュのみを破棄する。
    /// エージェントが PR を作成した直後（ターン終了時）に即座にバッジを反映させるために使用する。
    /// オフライン環境での不要な再試行ループを防ぐため、実際に「PR なし」がキャッシュされていた場合のみクールダウンを解除する。
    public static func forgetAbsent(worktree: String) {
        lock.lock()
        if let found = entries[worktree], found.ref == nil {
            entries.removeValue(forKey: worktree)
            order.removeAll { $0 == worktree }
            failures.removeValue(forKey: worktree)
        }
        lock.unlock()
    }

    /// 対象 worktree のキャッシュと失敗記録を全破棄する
    private static func forget(_ worktree: String) {
        lock.lock()
        entries.removeValue(forKey: worktree)
        order.removeAll { $0 == worktree }
        failures.removeValue(forKey: worktree)
        lock.unlock()
    }

    /// 取得成功時のキャッシュ有効期間（5分。マージ等のステータス変化に追従するため）
    private static let foundTTL: TimeInterval = 5 * 60
    /// PR なし（absent）時のキャッシュ有効期間（2分。PR 作成を早期検知するため短めに設定）
    private static let absentTTL: TimeInterval = 2 * 60
    /// 取得失敗時の再試行クールダウン間隔（10分）
    private static let retryInterval: TimeInterval = 10 * 60
    /// キャッシュエントリの上限件数
    private static let limit = 200

    private static func maxAge(of ref: PullRequestRef?) -> TimeInterval {
        ref == nil ? absentTTL : foundTTL
    }

    private struct Entry {
        var branch: String
        var ref: PullRequestRef?
        var at: Date
    }

    private static func entry(for worktree: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[worktree]
    }

    private static func remember(_ worktree: String, branch: String, ref: PullRequestRef?) {
        lock.lock()
        if entries[worktree] == nil { order.append(worktree) }
        entries[worktree] = Entry(branch: branch, ref: ref, at: Date())
        failures.removeValue(forKey: worktree)
        while order.count > limit {
            // キャッシュ破棄時にクールダウン記録も削除し、次回問い合わせ時に手元キャッシュなしのまま待機し続けるのを防ぐ
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
            failures.removeValue(forKey: evicted)
        }
        lock.unlock()
    }

    private static func isCoolingDown(_ worktree: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let failed = failures[worktree] else { return false }
        return Date().timeIntervalSince(failed) < retryInterval
    }

    private static func noteFailure(_ worktree: String) {
        lock.lock()
        failures[worktree] = Date()
        // メモリリーク防止のため失敗記録にも上限を設け、最古のエントリを破棄する
        if failures.count > limit,
           let oldest = failures.min(by: { $0.value < $1.value })?.key, oldest != worktree {
            failures.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    private static var entries: [String: Entry] = [:]
    private static var order: [String] = []
    private static var failures: [String: Date] = [:]
    private static let lock = NSLock()
}
