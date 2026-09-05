import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import UseCaseTask
import Utility

/// worktree を数え上げる。表示側の共通の入り口 (CollectTasks の worktree 版)。
///
/// セッションが終わっても worktree は残る。台帳から行が消えたあとも
/// ディスクには中身の入った作業場が残り、それが溜まっていくのが困りごとなので、
/// セッションではなく場所のほうから数える。
///
/// 見に行くのは台帳が一度でもセッションを見たリポジトリだけ。
/// ディスク全体を漁ると、proctor と関係のない作業場まで並ぶことになる。
public enum CollectWorktrees {
    /// - Parameters:
    ///   - repo: このリポジトリ本体だけに絞る。allRepos が true なら無視される
    ///   - allRepos: 覚えているリポジトリを全部見る
    ///   - withOrigin: 持ち主 (remote) まで引く。**既定は false。要る人だけが払う**
    ///     (理由は CollectTasks.run と同じ)
    ///   - countDiff: 未コミットの変更を数える。**既定は true (今までどおり)**。
    ///     false にすると `diffKnown` が false のまま返るので、
    ///     `isRemovable` も立たない。**数え切れていないものを「消してよい」と
    ///     言わないための正しい落ち方**だが、画面の上では「片付けるものが無い」に
    ///     見えてしまうので、切ってあると分かる字を出すのは呼ぶ側の仕事
    ///   - tasks: 突き合わせるセッション。既に集めてあるなら渡す。
    ///     渡さなければここで集める (CLI は集め直しても一度きりだが、
    ///     アプリは手元の一覧をそのまま使えるので git も台帳も読み直さずに済む)
    ///   - also: 台帳が覚えていなくても見に行くリポジトリ。
    ///     いま人が見ている場所を混ぜるために使う。台帳には書かないので、
    ///     ちょっと覗いただけのリポジトリが記憶の枠を食うことはない
    public static func run(repo: String? = nil, allRepos: Bool = false,
                           withOrigin: Bool = false,
                           countDiff: Bool = true,
                           tasks: [CollectedTask]? = nil,
                           also: [String] = [],
                           now: Int = Int(Date().timeIntervalSince1970))
        -> [CollectedRepoWorktrees] {
        runDetailed(repo: repo, allRepos: allRepos, withOrigin: withOrigin,
                    countDiff: countDiff,
                    tasks: tasks, also: also, now: now).groups
    }

    /// 数え上げた結果と、**読み切れたかどうか**。
    ///
    /// - Returns: `incomplete` は「実体はあるのに git が答えなかったリポジトリがあった」。
    ///   一覧を丸ごと置き換える側 (アプリ) は、これが立っていたら**前の値を残す**。
    ///   読めなかったことを「worktree が無い」として映すと、
    ///   何も起きていないのに行が消えたように見える
    /// - Parameter repos: 台帳が覚えているリポジトリ。渡さなければここで読む。
    ///   `tasks` と同じ分担で、既に読んであるなら渡す (アプリは同じ台帳を
    ///   「一覧に残すか」の判断とも分け合うので、読むのは1回で済む)。
    ///   **`run` のほうには足していない** —— 使うのはここを呼ぶアプリだけで、
    ///   対称性のためだけの引数は「これは誰が使うのか」を探させることになる
    public static func runDetailed(repo: String? = nil, allRepos: Bool = false,
                                   withOrigin: Bool = false,
                                   countDiff: Bool = true,
                                   tasks: [CollectedTask]? = nil,
                                   repos: [String: Int]? = nil,
                                   also: [String] = [],
                                   now: Int = Int(Date().timeIntervalSince1970))
        -> (groups: [CollectedRepoWorktrees], incomplete: Bool) {
        // 自分で集める回にも同じ答えを渡す。ここで数えてしまうと、
        // 「数えない」と言われた回に git がセッションのぶんだけ起きる
        let sessions = tasks ?? CollectTasks.run(allRepos: true, countDiff: countDiff)

        // 覚えているリポジトリと、いま動いているセッションのリポジトリを合わせる。
        // 台帳を覚えるより前から居座っているセッションがあっても取りこぼさない
        var lastSeen = repos ?? LedgerStore.repos()
        for task in sessions where lastSeen[task.repo] == nil {
            lastSeen[task.repo] = task.updatedAt
        }

        // 覚えていない場所は、時刻の分からないもの (0) として末尾に置く。
        // 出す・出さないを決めるのは呼ぶ側で、ここは聞かれたら見に行く
        for path in also where lastSeen[path] == nil { lastSeen[path] = 0 }

        var targets = Array(lastSeen.keys)
        if !allRepos, let repo {
            targets = targets.filter { $0 == repo }
            // 覚えていないリポジトリで聞かれることもある (そこで一度も
            // セッションを動かしていない)。聞かれた場所は素直に見に行く
            if targets.isEmpty { targets = [repo] }
        }

        // 台帳の時刻の新しい順。同じ時刻ならパスで決着をつける
        // (辞書の並びは実行のたびに変わるので、任せると順序が揺れる)。
        // **「最後に見た順」とは限らない** —— この時刻は24時間に1回しか
        // 書き直されないので (RecordHookEvent.repoMemoryRefresh)、
        // 同じ日のうちに触った2つの順は入れ替わりうる
        let ordered = targets.sorted {
            let (a, b) = (lastSeen[$0] ?? 0, lastSeen[$1] ?? 0)
            return a != b ? a > b : $0 < $1
        }

        var groups: [CollectedRepoWorktrees] = []
        var incomplete = false
        for path in ordered {
            guard FileManager.default.fileExists(atPath: path) else {
                continue  // 場所ごと消えている。これは確かな答えなので黙って外す
            }
            guard let group = collect(repo: path, sessions: sessions,
                                      withOrigin: withOrigin, countDiff: countDiff,
                                      now: now) else {
                // 実体はあるのに git が答えない。**「無い」ではなく「分からない」**
                incomplete = true
                continue
            }
            groups.append(group)
        }
        return (groups, incomplete)
    }

    /// リポジトリ1つぶんを数える。git が答えなければ nil。
    ///
    /// **空の一覧は「worktree が無い」ではなく「読めなかった」。** git として
    /// 生きているリポジトリなら本体が必ず1件は出るので、空で返るのは
    /// 問い合わせに失敗したときだけ。呼ぶ側はそれを分からないものとして扱う。
    static func collect(repo: String, sessions: [CollectedTask],
                        withOrigin: Bool, countDiff: Bool,
                        now: Int) -> CollectedRepoWorktrees? {
        let entries = GitClient.worktrees(repo)
        guard !entries.isEmpty else { return nil }

        // 取り込み先と、そこに入り終わったブランチは1リポジトリにつき1回だけ引く。
        // worktree ごとに聞くと、同じ答えのために git を何度も起こすことになる
        let base = GitClient.defaultBranch(repo)
        // "origin/main" から "main" を取り出す。取り込み先そのものに乗っている
        // worktree を「マージ済み」と呼ばないための照合に使う
        let baseName = base.map { $0.contains("/") ? String($0.split(separator: "/").last!) : $0 }
        let merged = base.map { GitClient.mergedBranches(repo, into: $0) } ?? []

        let collected = entries.enumerated().map { index, entry in
            let isMain = index == 0  // git は本体を先頭に出す
            let exists = FileManager.default.fileExists(atPath: entry.path)
            let here = sessions.filter { $0.worktree == entry.path }.map(\.id)
            // 中身を見られる場所だけ数える。ベアリポジトリには作業ツリーが無く、
            // 実体を失っている場所は開くことすらできない
            let countable = exists && !entry.isBare
            // 数えないと決めた回も nil にする。**0 を入れて「変更なし」に
            // しないこと** — diffKnown が立ったまま空の差分が伝わると、
            // 数えていない場所が「消してよい候補」として並んでしまう
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

        // 本体を先頭に置いたまま、残りは新しく触ったものから並べる。
        // 放置の度合いを見る一覧なので、古いものが下に沈むほうが読みやすい
        let sorted = collected.filter(\.isMain)
            + collected.filter { !$0.isMain }.sorted {
                $0.lastCommitAt != $1.lastCommitAt
                    ? $0.lastCommitAt > $1.lastCommitAt : $0.path < $1.path
            }

        return CollectedRepoWorktrees(
            repo: repo,
            repoName: URL(fileURLWithPath: repo).lastPathComponent,
            origin: withOrigin ? ResolveRepoOrigin.run(repo: repo) : nil,
            worktrees: sorted)
    }

    /// 取り込み済みか。
    ///
    /// **取り込み先そのものに乗っている worktree は「マージ済み」と呼ばない。**
    /// main は必ず main の祖先なので素直に数えると常に真になり、
    /// 幹を片付けの候補に挙げてしまう。あそこは終わった作業ではない。
    ///
    /// detached (ブランチを持たない) も同じく数えない。名前が無いものは
    /// 取り込み先との関係を言い当てられないので、判断は人に返す。
    static func isMerged(entry: GitClient.WorktreeEntry, isMain: Bool,
                         merged: Set<String>, baseName: String?) -> Bool {
        guard !isMain, let branch = entry.branch, !entry.isDetached,
              branch != baseName else { return false }
        return merged.contains(branch)
    }

    /// その場所の未コミットの変更。数え方は CollectTasks.diff と同じ
    /// (見たいのは「まだ手元にしかない仕事」なので HEAD からの差分)。
    ///
    /// **どちらか一方でも聞けなかったら nil。** 半端に数えた値を返すと、
    /// 片方が空だっただけの場所が「変更なし」として片付けの候補に並ぶ。
    /// 欠けたぶんを 0 で埋めるセッションの側 (`CollectTasks.diff`) とはそこが違う
    static func diff(at worktree: String) -> DiffCounts? {
        let counted = CountChanges.run(worktree: worktree)
        guard let lines = counted.lines, let untracked = counted.untracked else { return nil }
        return DiffCounts(added: lines.added, removed: lines.removed,
                          untracked: untracked, binary: lines.binary,
                          changedFiles: lines.files)
    }
}
