import Foundation

/// 未コミットの変更を数える。**数え直すか、覚えた答えを返すかを決めるのはここ**。
///
/// 覚えるのは git の生の答えで、**潰し方は呼ぶ側に任せる**。同じ数字を欲しがる側が
/// 2つあり、聞けなかったときの扱いが違うため。`CollectTasks.diff(for:)` は
/// 行数と未追跡を**別々に** 0 へ潰し (コミットの無いリポジトリでは
/// `diff HEAD` だけが失敗するので、片方を巻き込むと未追跡の数まで消える)、
/// `CollectWorktrees.diff(at:)` は片方でも欠けたら nil にする
/// (半端な数字は「消してよい」の判断材料にならない)。
/// ここで解釈してしまうと、どちらかの意味に寄せた時点でもう片方が壊れる
/// (PR #15 で差分の使い回しが見送られたのはこれが理由)。
///
/// 覚えているのはプロセスの中だけなので、**一回きりで終わる CLI では
/// 毎回が「最初の1回」**になる (`ResolveRepoOrigin` と同じ性質で、
/// アプリのように生き続けるプロセスでだけ効く)。
public enum CountChanges {
    /// git がそのまま答えた形。nil は「聞けなかった」
    public struct Counted {
        public let lines: (added: Int, removed: Int, binary: Int, files: Int)?
        public let untracked: Int?
    }

    public static func run(worktree: String) -> Counted {
        lock.lock()
        if let remembered = cache[worktree] {
            lock.unlock()
            return remembered
        }
        lock.unlock()

        // git を呼んでいる間はロックを離す。ここを抱えたままにすると、
        // 一覧を数え直すときに worktree の数だけ順番待ちが起きる
        // (`ResolveRepoOrigin` と同じ)
        let counted = Counted(lines: GitClient.changedLines(worktree, since: "HEAD"),
                              untracked: GitClient.untrackedCount(worktree))

        // **聞けなかったことは覚えない。** 覚えると、git が一度答えなかっただけで
        // 次にそこが編集されるまで欠けた答えが出続ける
        guard counted.lines != nil, counted.untracked != nil else { return counted }
        lock.lock()
        cache[worktree] = counted
        lock.unlock()
        return counted
    }

    /// ここが変わったので次は数え直す。呼ぶ側 (アプリ) が `WorktreeWatcher` から
    /// 受け取った場所をそのまま渡す
    public static func invalidate(_ worktrees: Set<String>) {
        guard !worktrees.isEmpty else { return }
        lock.lock()
        for worktree in worktrees { cache.removeValue(forKey: worktree) }
        lock.unlock()
    }

    /// 覚えているものを全部捨てる。
    /// **見張りの取りこぼし (`WorktreeWatcher`) から戻るための道**なので、
    /// 呼ぶ側はときどきここを通すこと
    public static func forgetAll() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    private static var cache: [String: Counted] = [:]
    private static let lock = NSLock()
}
