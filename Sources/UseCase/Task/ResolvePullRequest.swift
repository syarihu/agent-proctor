import Foundation
import Model
import RepositoryGit
import RepositoryGitHub

/// worktree に紐づく PR を1つ手に入れる。
///
/// gh を叩くのは `GitHubClient`、ブランチを読むのは `GitClient` の仕事で、
/// ここが持つのはそれ以外の3つ ——「そもそも聞きに行ってよい相手か」
/// 「何秒で古いと見なすか」「取れなかった答えをどう扱うか」。
///
/// **いつ聞き直すかの間隔はすべてここに置く** (`OrganizationGrouping` と同じ役目)。
///
/// **`CollectTasks.run()` からは呼ばないこと。** あちらは台帳が動くたびに
/// (= ツール1回ごとに) 通る道で、ここは1回につきネットワークに出る。
/// 混ぜると、いちばん編集している最中に worktree の数だけ gh が起きる。
public enum ResolvePullRequest {
    /// 手元にあればそれを、無ければ gh に聞いて返す。
    ///
    /// **ネットワークに出るので、待たせてよいところから呼ぶこと。**
    ///
    /// - Parameters:
    ///   - worktree: 覚えておく鍵。ブランチのほうは覚えた値と一緒に持ち、
    ///     出す前に必ず今のブランチと突き合わせる (`Entry.branch`)
    ///   - origin: リポジトリの持ち主。gh が答えられる相手かの判断に使う
    /// - Returns: PR。無いか、手に入らなければ nil
    public static func run(worktree: String, origin: RepoOrigin?) -> PullRequestRef? {
        // **GitHub 以外には聞きに行かない。** gh は GitHub 専用の道具なので、
        // GitLab や remote の無いリポジトリで呼んでも失敗するだけ。
        // ここで弾いておくと、そのぶんプロセスが起きない
        guard origin?.isGitHub == true, GitHubClient.executable != nil else { return nil }

        // **期限を見るより先にブランチを読む。** PR が紐づいているのは worktree では
        // なくブランチで、台帳の branch は登録した時点の値なので当てにできない
        // (セッションの途中で `git switch` すればずれる)。
        //
        // ここで git が1つ起きるが、この関数を呼ぶのは表示側の見張り (30秒に1回) だけで、
        // 画面の描き直しからは呼ばれない (あちらは取れた答えの辞書を読むだけ)。
        // worktree ごとに30秒に1回の `rev-parse` は、既に10秒ごとに回っている
        // 差分の数え直しに比べれば誤差でしかない
        let branch = GitClient.currentBranch(worktree)
        // detached や、消えてしまった worktree。**覚えているものも捨てる。**
        // 残すと、下の `.unavailable` の道を通って古い番号が無期限に出続ける
        guard !branch.isEmpty, branch != "HEAD", branch != "-" else {
            forget(worktree)
            return nil
        }

        let remembered = entry(for: worktree)
        // **ブランチが変わっていたら、覚えているものは別の PR。** 期限の中でも出さない
        let usable = remembered?.branch == branch ? remembered : nil
        if let usable, Date().timeIntervalSince(usable.at) < maxAge(of: usable.ref) {
            return usable.ref
        }
        // 少し前に聞けなかった相手には、しばらく聞き直さない。取れない理由
        // (通信できない・認証が切れている) は数十秒では変わらないことが多く、
        // 一覧が出ている間ずっと gh を起こし続けることになる
        guard !isCoolingDown(worktree) else { return usable?.ref }

        let looked = GitHubClient.pullRequest(worktree: worktree, branch: branch)
        // **聞いている間に切り替わっていないか、もう一度見る。** gh は0.7秒ほど
        // ネットワークに出るので、その間に `git switch` される余地がある。
        // 気づかずに覚えると、切り替えた先のブランチに前のブランチの番号が出て、
        // しかも押すと別の PR が開く (次に見張りが回るまで直らない)。
        //
        // **ただし「PR は無い」とは言わない。** ここで nil を返すと表示側は
        // バッジを消す。A → B → A と行き来しただけのときは A の答えを
        // 覚えているので、それを出し直す。言い切ってしまうと、
        // 切り替えて戻るたびに正しいバッジが30秒消える
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
            // **「無い」も覚える。** 覚えないと、PR を作っていないブランチほど
            // 見張りが回るたびに gh を起こすことになる
            remember(worktree, branch: branch, ref: nil)
            return nil
        case .unavailable:
            noteFailure(worktree)
            // **聞けなかった答えは書かない。** ここで「無い」として覚えると、
            // gh が一時的に使えないだけの状態と本物の「PR 無し」が区別できなくなる。
            // 前に取れていたものが**同じブランチのものなら**、それを出し続ける
            return usable?.ref
        }
    }

    /// 「PR は無い」と覚えたものだけ捨てる。次に呼ばれたときに聞き直す。
    ///
    /// **ターンの切れ目で呼んでもらうために置いてある。** `gh pr create` を
    /// 走らせた直後がまさにそこなので、期限 (2分) を待たずに番号を出せる。
    /// 見つかっているものを捨てないのは、捨てても同じ答えが返るだけだから。
    ///
    /// **クールダウンを解くのも、実際に「無い」を捨てたときだけ。** ここを
    /// 素通しにすると、gh が使えない環境 (未ログイン・オフライン) でターンが
    /// 終わるたびに10分の待ちが解け、常駐したまま gh を起こし続けることになる。
    public static func forgetAbsent(worktree: String) {
        lock.lock()
        if let found = entries[worktree], found.ref == nil {
            entries.removeValue(forKey: worktree)
            order.removeAll { $0 == worktree }
            failures.removeValue(forKey: worktree)
        }
        lock.unlock()
    }

    /// 覚えていることを丸ごと捨てる。ブランチが読めなくなった worktree 用
    private static func forget(_ worktree: String) {
        lock.lock()
        entries.removeValue(forKey: worktree)
        order.removeAll { $0 == worktree }
        failures.removeValue(forKey: worktree)
        lock.unlock()
    }

    /// 見つかった答えを持ち越す時間。
    ///
    /// 番号も URL も変わらないが、**状態 (open → merged) は変わる**ので
    /// 置きっぱなしにはしない。5分あれば、マージしてタブに戻ってくる頃には追いつく
    private static let foundTTL: TimeInterval = 5 * 60
    /// 「PR は無い」を持ち越す時間。**見つかったときより短くする。**
    /// PR は作業の途中で生えるものなので、作った直後にできるだけ早く出したい
    private static let absentTTL: TimeInterval = 2 * 60
    /// 聞けなかった相手に聞き直すまでの間隔
    private static let retryInterval: TimeInterval = 10 * 60
    /// 覚えておく worktree の数。**際限なく増やさない。** ブランチを切り替えても
    /// 作業場を作り直しても鍵が増える。
    ///
    /// 捨てるのは**入れた順**で、使った順ではない (`TaskStore.repoOfDirectory` と同じ)。
    /// 参照のたびに順番を組み替える価値があるほど、ここの当たり外れは高くつかない
    private static let limit = 200

    private static func maxAge(of ref: PullRequestRef?) -> TimeInterval {
        ref == nil ? absentTTL : foundTTL
    }

    private struct Entry {
        /// この答えを得たときに出ていたブランチ。**出す前に必ず突き合わせる**
        var branch: String
        /// nil は「聞いた上で、PR は無かった」。聞けなかったものはここに入らない
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
            // **クールダウンも一緒に落とす。** 覚えを捨てたのに待ちだけ残ると、
            // 次に聞かれたとき、手元に何も無いのに問い合わせもしない状態になる
            // (最大10分、番号が出ないまま何も起きない)
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
        // **こちらにも上限を掛ける。** 成功するまで消えない記録なので、
        // gh が使えないまま worktree を作り替え続けると際限なく積み上がる。
        // 数が動くのは失敗した回だけなので、そのときに並べ替えても値段は知れている
        if failures.count > limit,
           let oldest = failures.min(by: { $0.value < $1.value })?.key, oldest != worktree {
            failures.removeValue(forKey: oldest)
        }
        lock.unlock()
    }

    private static var entries: [String: Entry] = [:]
    /// 覚えた順。入れた順に捨てるために持つ
    private static var order: [String] = []
    private static var failures: [String: Date] = [:]
    private static let lock = NSLock()
}
