import Foundation
import Model
import RepositoryGit

/// リポジトリのリモート情報（RepoOrigin）を解決・キャッシュ管理する。
/// git コマンドを呼び出すため、取得結果（リモートが存在しない場合も含む）をメモリ上にキャッシュする。
public enum ResolveRepoOrigin {
    /// - Parameter repo: リポジトリ本体のパス
    /// - Returns: リモート情報。未設定またはパース不可の場合は nil
    public static func resolve(repo: String) -> RepoOrigin? {
        lock.lock()
        if let remembered = cache[repo] {
            lock.unlock()
            return remembered
        }
        lock.unlock()

        // 並行処理のブロッキングを防ぐため、git 呼び出し中はロックを解放する
        let origin = GitClient.remoteURL(repo).flatMap(RepoOrigin.parse)

        lock.lock()
        cache[repo] = origin
        lock.unlock()
        return origin
    }

    /// 未問い合わせと取得失敗（リモートなし）を区別するため Optional の二重構造でキャッシュする
    private static var cache: [String: RepoOrigin?] = [:]
    private static let lock = NSLock()
}
