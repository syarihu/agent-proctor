import Foundation
import Model
import RepositoryGit
import RepositoryLedger

/// セッションも worktree も無くなったあとも、一覧に残しておくリポジトリ。
///
/// 一覧が映すのは「今どうなっているか」なので、素直に作ると、最後のタブを
/// 閉じた瞬間にリポジトリは見出しごと消える。それは一覧としては正しいが、
/// **さっきまで居た場所へ戻る道がそこで切れる。** ここは「まだ残しておく」
/// リポジトリを答えるだけの役目で、残ったものは動きのあるものの下に落ちる
/// (どう並ぶかを決めるのは表示側の `TaskGrouping`)。
///
/// **git を起こさない。** 見るのは台帳だけ。
public enum CollectRecentRepos {
    /// 残しておく期間。これより古いものは、タブが開いているときにだけ出る。
    ///
    /// 「さっきまで居た場所」への戻り道なので、1週間より前のものまで
    /// 一覧に居座らせると、今動いているものが下に押し出されるだけになる
    public static let window = 7 * 24 * 3600

    /// - Parameters:
    ///   - repos: 台帳が覚えているリポジトリ。渡さなければここで読む
    ///     (呼ぶ側が事実を渡せる形にしてあるのは CollectWorktrees と同じ)
    ///   - within: 何秒前までを「最近」と呼ぶか
    ///   - now: 今の時刻。試すときに差し替えられるように受ける
    /// - Returns: 一覧に残しておくリポジトリ本体のパス
    ///
    /// **実体がまだあるかはここでは見ない。** `CollectWorktrees.runDetailed` が
    /// 消えたパスを既に落としているので、この集合を通っても群が無ければ
    /// 一覧には出ない。同じことを2か所で見ると、片方だけ直したときに食い違う。
    ///
    /// **台帳が覚えている時刻は「最後に見た時刻」ではない。** 書き直すのは
    /// 24時間に1回だけなので (`RecordHookEvent.repoMemoryRefresh`)、
    /// 実際には「直近24時間の枠で最初に見た時刻」になる。**7日の線は最大1日
    /// 早く切れる。** それでも書き込みを増やさないのは、フックのたびに台帳の
    /// 更新時刻が動き、そのたびにサイドバーが数え直すことになるため。
    ///
    /// **台帳は読むだけで、書かない。古いものを刈らない。** 7日の線は表示にだけ
    /// 掛ける。`repos` は `CollectWorktrees` が「どこを見に行くか」を決める元でも
    /// あるので、ここで古い行を落とすと、いちばん見たいもの——長く放置された
    /// worktree——が worktree の一覧からも消えてしまう。
    public static func collect(repos: [String: Int]? = nil,
                               within: Int = window,
                               now: Int = Int(Date().timeIntervalSince1970)) -> Set<String> {
        let lastSeen = repos ?? LedgerStore.repos()
        return Set(lastSeen.filter { _, seen in
            // 時刻を持たないものは残さない。いつ見たのか分からないものは、
            // 「最近」かどうかを言い当てられない。
            // now < seen (時計がずれている・巻き戻った) は最近の側に倒す。
            // 引き算が負になるだけで、直前に見た場所であることに変わりはない
            seen > 0 && now - seen <= within
        }.keys)
    }
}
