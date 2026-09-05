import Combine
import Foundation
import Model
import UseCaseTask

/// 行に出す PR を預かる。
///
/// **View から直接 gh を呼ばせないため**の層 (`OrgAvatarStore` と同じ作り)。
/// SwiftUI は同じ行を何度でも描き直すので、描画のたびに問い合わせることになる。
/// ここで取りに行き、取れたら `@Published` で描き直させる。
///
/// どこまで覚えていてよいか・いつ聞き直すかは Kit の `ResolvePullRequest` が
/// 持っている。ここが持つのは「重ねて取りに行かないこと」
/// 「見えていない間は聞きに行かないこと」「いっぺんに走らせすぎないこと」の3つ。
@MainActor
public final class PullRequestStore: ObservableObject {
    /// worktree ごとの PR。無いものは載せない (行は何も出さない)
    @Published public private(set) var refs: [String: PullRequestRef] = [:]

    public init() {}

    /// いま取りに行っている最中の worktree。**走らせないためだけの印。**
    ///
    /// SwiftUI は同じ行を何度でも描き直すので、これが無いと取得が重なる。
    /// 結果は覚えない —— 覚えると、一度失敗した worktree に二度と聞かなくなる
    /// (聞き直しの間隔は `ResolvePullRequest` の持ち物)
    private var loading: Set<String> = []

    /// 取りに行っている最中に「もう一度」と言われたもの。終わったら1回だけ聞き直す。
    ///
    /// **捨ててはいけない。** ターンの切れ目の求めは `gh pr create` の直後に来るが、
    /// そのとき走っている取得は PR を作る**前**に始まっているので、
    /// 「PR は無い」を後から書き込む。ここで拾い直さないと、
    /// 早く出すために用意した合図が空振りして、また2分待つことになる
    private var pendingForced: Set<String> = []

    /// サイドバーが見えているか。**見えていない間は聞きに行かない。**
    ///
    /// 一覧が畳まれても SwiftUI の `.task` は生きているので、放っておくと
    /// 誰も見ていない番号のために常駐アプリが gh を鳴らし続ける
    /// (`TaskStore.setCollecting` が git に対してやっているのと同じ考え方)。
    private var enabled = false

    /// いま一覧に出ている worktree。**一度も知らされていない間は nil。**
    /// 空集合と取り違えると、最初の掃除が来る前に取れた答えを全部捨ててしまう
    private var active: Set<String>?

    /// ターンの切れ目の求めを、いま粘っている最中の worktree。
    ///
    /// **重ねて走らせない。** 状態は短い間に何度も動く (実行中 → 完了 → 失敗 など) ので、
    /// 求めのたびにループを立てると、同じ worktree に何本も枠待ちが並ぶ。
    /// 覚えを捨てるのはどのループも同じことをするので、1本で足りる
    private var forcing: Set<String> = []

    /// 期限が切れていないか見に行く間隔。
    ///
    /// **ここを短くしても通信は増えない。** 実際に gh を叩くかどうかは
    /// `ResolvePullRequest` の期限が決めるので、これが決めるのは
    /// 「期限切れに気づくまでの遅れ」だけ。サイドバーを開き直したときに
    /// 番号が出るまでの待ち時間でもあるので、あまり長くはしない
    private static let tick: Duration = .seconds(30)
    /// 混んでいて見送ったときに、次を試すまでの間。
    /// ここまで待たせると初回表示が遅れるので、普段の間隔とは別に短く持つ
    private static let busyRetry: Duration = .seconds(2)
    /// 同時に走らせる問い合わせの数。
    ///
    /// **一斉に走らせない。** 一覧に出ている worktree の数だけ gh が同時に起きる
    /// ことになり、gh が使えない環境では15秒で打ち切られるまでのプロセスが
    /// まとめて居座る。順番待ちは見張りの回り直しに任せる (`busyRetry`) ——
    /// 待ち行列を自前で持つと、行が消えて `.task` が畳まれたときに
    /// 並んだままのものが起きられなくなる
    private static let maxConcurrent = 4
    /// ターンの切れ目の求めが、枠の埋まりで弾かれたときに入り直す回数。
    ///
    /// **枠を1本占め続けられる最長より長く粘る。** 先客は gh の待ち切り(15秒)に
    /// 畳むための猶予(2秒)が乗るので、最悪で17秒ほど居座る。2秒おきに12回で
    /// 24秒あれば、そこを越えられる。
    ///
    /// それでも取りこぼす回はある。**そのときも番号が出ないままにはならない** ——
    /// 先に `forgetAbsent` で覚えを捨ててあるので、見張りの次の回り (最大30秒) が
    /// 拾う。ここで守っているのは「出るのが早いこと」であって、「出ること」ではない
    private static let forcedAttempts = 12

    /// サイドバーの表示が切り替わったときに呼ぶ。
    public func setEnabled(_ on: Bool) { enabled = on }

    /// 1つの worktree を見張り続ける。行が出ている間だけ回る。
    ///
    /// SwiftUI の `.task` から呼ぶ。行が一覧から消えれば畳まれるので、
    /// 居なくなった作業場のために眠り続けることはない。
    func watch(worktree: String, origin: RepoOrigin?) async {
        while !Task.isCancelled {
            let ran = await load(worktree: worktree, origin: origin, forced: false)
            // 見送った回は普段の間隔まで待たない。待つと初回表示で
            // 5行目以降の番号が30秒出てこないことになる
            do { try await Task.sleep(for: ran ? Self.tick : Self.busyRetry) } catch { return }
        }
    }

    /// ターンの切れ目で呼ぶ。**`gh pr create` の直後がここ。**
    ///
    /// 「PR は無い」と覚えたものだけ捨てて、すぐ聞き直す。期限 (2分) を
    /// 待たずに番号が出る。
    func noteTurnEnded(worktree: String, origin: RepoOrigin?) {
        ResolvePullRequest.forgetAbsent(worktree: worktree)
        guard !forcing.contains(worktree) else { return }
        forcing.insert(worktree)
        Task {
            defer { forcing.remove(worktree) }
            // **枠が埋まっていても諦めない。** ここで引き下がると、拾い直すのは
            // 見張りの次の回りになる。あちらは直前に取りに行けていれば30秒眠るので、
            // 早く出すために用意した合図が、いちばん混んでいるときだけ効かなくなる
            for _ in 0..<Self.forcedAttempts {
                if await load(worktree: worktree, origin: origin, forced: true) { return }
                do { try await Task.sleep(for: Self.busyRetry) } catch { return }
            }
        }
    }

    /// いま一覧に出ている worktree だけを残す。
    ///
    /// **取れた答えは行が消えても残り続ける。** 見張りのほうは `.task` が
    /// 畳まれて止まるが、辞書に載せたものを外す者がいない。作業場を作っては
    /// 捨てる使い方だと、常駐している間ずっと積み上がることになる
    public func keep(worktrees: Set<String>) {
        active = worktrees
        let stale = refs.keys.filter { !worktrees.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale { refs.removeValue(forKey: key) }
    }

    /// - Returns: 実際に取りに行ったら true。混んでいて見送ったら false
    @discardableResult
    private func load(worktree: String, origin: RepoOrigin?, forced: Bool) async -> Bool {
        // 見えていない間は聞きに行かない。**こちらは「見送った」とは言わない** ——
        // 誰も見ていないのだから、普段の間隔で眠っていてよい
        guard enabled else { return true }
        // **一覧から消えた行のために gh を起こさない。** 枠待ちで粘っている間に
        // 行が消えることがある。答えは `apply` で捨てられるので害は無いが、
        // 誰も見ないもののために git と gh を1回ずつ起こすことになる。
        //
        // **ここは「見送った」を返す。** 掃除の合図 (`keep`) は親の `.onChange` から、
        // 行の見張りは子の `.task` から走るが、**SwiftUI はこの2つの順序を決めていない。**
        // 現れたばかりの行がまだ `active` に載っていないことがあり、
        // 普段の間隔を返すと、そのバッジが30秒出てこない。
        // 本当に消えた行なら `.task` ごと畳まれるので、空回りにはならない
        guard active?.contains(worktree) != false else { return false }
        if loading.contains(worktree) {
            // 走っている最中の求めは、その結果が古くなるので預かっておく
            if forced { pendingForced.insert(worktree) }
            return true
        }
        guard loading.count < Self.maxConcurrent else { return false }

        loading.insert(worktree)
        // gh とネットワーク、それに git を待つのでメインスレッドから外す
        let found = await Task.detached(priority: .utility) {
            ResolvePullRequest.run(worktree: worktree, origin: origin)
        }.value
        loading.remove(worktree)
        apply(found, for: worktree)

        // 取りに行っている間に来た「もう一度」を、ここで1回だけ拾う。
        // 印は先に外す —— 残したまま入り直すと、聞き直すたびにまた預かることになる
        if pendingForced.remove(worktree) != nil {
            ResolvePullRequest.forgetAbsent(worktree: worktree)
            await load(worktree: worktree, origin: origin, forced: false)
        }
        return true
    }

    private func apply(_ found: PullRequestRef?, for worktree: String) {
        // **掃除のあとに戻ってきた答えを載せ直さない。** 行が消えても
        // `Task.detached` は走り切るので、`keep` で外した鍵がここで復活する。
        // そうなると、次に顔ぶれが変わるまで誰のものでもない PR が残る
        guard active?.contains(worktree) != false else { return }
        guard refs[worktree] != found else { return }
        // **消えたときも映す。** 辞書は nil の代入が削除にならないので、
        // 明示的に外す。マージ後に closed へ回った PR が取り下げられたときや、
        // ブランチを切り替えて PR が無くなったときにここを通る
        if let found {
            refs[worktree] = found
        } else {
            refs.removeValue(forKey: worktree)
        }
    }
}
