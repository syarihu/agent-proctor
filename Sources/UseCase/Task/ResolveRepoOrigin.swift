import Foundation
import Model
import RepositoryGit

/// リポジトリの持ち主を突き止める。
///
/// git を起動するので、一度引いた答えは覚えておく。remote が付け替わることは
/// あるが、セッションが動いている最中に変わるものではないので、プロセスが
/// 生きている間は同じ答えでよい。**付け替えたときはアプリを立ち上げ直す**
/// (捨てる口を用意しても、そこへ辿り着く操作が画面にも CLI にも無い)。
///
/// **引けなかったことも覚える。** remote を持たないリポジトリを毎回聞き直すと、
/// 一覧を数え直すたびに答えの出ない git が起きる。無いことも1つの答えとして扱う。
///
/// 覚えているのはプロセスの中だけなので、**一回きりで終わる CLI には効かない。**
/// `proctor ls` が既定で持ち主を引かないのはそのため (`CollectTasks.collect`)。
public enum ResolveRepoOrigin {
    /// - Parameter repo: リポジトリ本体の場所 (worktree ではない)
    /// - Returns: 持ち主。remote が無い・読めない置き方なら nil
    public static func resolve(repo: String) -> RepoOrigin? {
        lock.lock()
        if let remembered = cache[repo] {
            lock.unlock()
            return remembered
        }
        lock.unlock()

        // git を呼んでいる間はロックを離す。ここを抱えたままにすると、
        // 一覧を数え直すときに worktree の数だけ順番待ちが起きる
        let origin = GitClient.remoteURL(repo).flatMap(RepoOrigin.parse)

        lock.lock()
        cache[repo] = origin
        lock.unlock()
        return origin
    }

    /// 値が nil であることと、まだ聞いていないことを区別するため二重の Optional で持つ
    private static var cache: [String: RepoOrigin?] = [:]
    private static let lock = NSLock()
}
