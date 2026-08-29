import Foundation
import Combine
import ProctorKit

/// 台帳を見張って、表示に使うものを配る。
///
/// **View から Repository を直接触らせないための層**でもある。台帳の読み方が
/// 変わっても、直すのはここだけで済むようにしておく。
///
/// 見張りを2段に分けているのは、値段が違うから。
///
///   - 台帳の更新時刻を見るだけ … stat 1回。状態の変化はここに必ず現れるので短く回す
///   - 一覧を数え直す           … worktree ごとに git を起動する。高いので絞る
///
/// さらに、コードを編集しても台帳は変わらない。差分の数字だけは台帳の変化を
/// 待っていても古いままなので、サイドバーが見えている間は定期的に数え直す。
@MainActor
final class TaskStore: ObservableObject {
    /// サイドバーが出ている間だけ更新される、git まで数えた一覧
    @Published private(set) var tasks: [CollectedTask] = []
    /// 台帳そのもの。git を呼ばないので常に持っておける。
    /// メニューの一覧や「開く」の照合はこちらを使う
    @Published private(set) var records: [TaskRecord] = []
    /// メニューバーの要約
    @Published private(set) var summary: [(status: String, count: Int)] = []
    /// エージェントごとのレートリミットキャッシュ。セッションが無くても残る
    @Published private(set) var agentRateLimits: [String: AgentRateLimits] = [:]
    /// リポジトリごとの worktree。セッションが終わっても残るものを見せるために持つ。
    /// 数えるのに git を起こすので、更新は自前の長い周期 (worktreeInterval) だけ
    @Published private(set) var worktrees: [CollectedRepoWorktrees] = []
    /// セッションも worktree も無くなっても、一覧に残しておくリポジトリ。
    ///
    /// タブを閉じた瞬間に見出しごと消えると、さっきまで居た場所へ戻る道が
    /// そこで切れる。残ったものは動きのあるものの下に落ちるだけなので、
    /// 今どうなっているかの見通しは変わらない。
    /// 誰を残すかを決めるのは `CollectRecentRepos`
    @Published private(set) var keptRepos: Set<String> = []
    /// いま見ている iTerm2 のタブ。台帳には無い情報なので外から入れてもらう
    /// (聞きに行くのは FocusWatcher。ここは表示のために預かるだけ)
    @Published private(set) var focusedSession: String?
    /// いま見ているタブがいるリポジトリ本体。エージェントが動いていない場所も含む。
    ///
    /// 台帳には書かない。台帳を書くのはフックの役目で、覗いただけの
    /// リポジトリを覚えると、覚えておける件数の枠をそれで食ってしまう
    @Published private(set) var currentRepo: String?
    /// セッションの guid ごとの iTerm2 タブ番号 (⌘N の N)。
    ///
    /// **台帳には書かない。** 番号はタブを開く・閉じる・並べ替えるたびに動くので、
    /// 台帳に持たせるとその都度書き込みが走り、一覧の組み直しを呼び続ける。
    /// 端末に聞けば分かるものなので、預かるだけにする
    /// (聞きに行くのは FocusWatcher)
    @Published private(set) var tabNumbers: [String: Int] = [:]

    /// 台帳の更新時刻を見に行く間隔。stat を叩くだけなので軽い
    private let pollInterval: TimeInterval = 0.5
    /// 台帳が変わらなくても数え直す間隔。git を起動するのでこちらは長く取る
    private let recountInterval: TimeInterval = 10
    /// worktree を数え直す間隔。一覧の数え直しよりさらに長い。
    /// worktree は作られたり消えたりが分単位の出来事なのに、数えるのは1件につき
    /// git を数回。セッションの差分と同じ速さで回すと、居るだけで git が鳴り続ける
    private let worktreeInterval: TimeInterval = 60

    private var pollTimer: Timer?
    private var lastModified: Date?
    private var lastRecount = Date.distantPast
    private var lastWorktreeCount = Date.distantPast
    /// 現在地を調べた結果。「git の外だった」も覚えるので Optional では持たない
    /// (Swift の辞書は nil の代入が削除になるため、覚えたつもりで毎回引き直しになる)
    private enum DirectoryOrigin {
        case repository(String), outside
        var repository: String? {
            if case .repository(let path) = self { return path }
            return nil
        }
    }
    /// 現在地 → 調べた結果と、調べた時刻。同じ場所を二度引かないための覚え書き。
    /// 際限なく増えないよう、古いものから捨てる
    private var repoOfDirectory: [String: (origin: DirectoryOrigin, at: Date)] = [:]
    /// 「git の外だった」を信じ続ける時間。
    ///
    /// git が起動できなかったのか、本当に git の外なのかは見分けられない
    /// (どちらも空で返ってくる)。取り違えたまま覚え込むと、**そのリポジトリが
    /// 一覧から消えたまま戻らない**ので、外だという答えにだけ期限を付けて聞き直す。
    /// リポジトリだと分かった答えのほうは変わらないので覚えたままでよい
    private let outsideAnswerTTL: TimeInterval = 60
    private var directoryOrder: [String] = []
    private let directoryCacheLimit = 200
    /// いちばん新しい問い合わせ。**答えが返る順は問い合わせた順とは限らない**ので、
    /// これと違う答えは捨てる (A→B と移ったあとに A の答えが届いて巻き戻るのを防ぐ)
    private var pendingDirectory: String?
    /// 最近いたリポジトリ (新しい順)。台帳が覚えていない場所を数えるために持つ
    private var visited: [String] = []
    /// いまセッションが乗っている場所。worktree の一覧はここだけを見て変わる。
    /// ツールが動くたびに台帳は変わるが、この顔ぶれが同じなら数え直す意味はない
    private var sessionPlaces: Set<String> = []
    /// 最後に worktree を数えたときの顔ぶれ
    private var countedPlaces: Set<String> = []
    /// いま数え直しが走っているか。重ねて起こさないための札
    private var recounting = false
    /// 走っている最中に来た数え直しの求め。終わったら1回だけ拾い直す
    private var pendingRecount = false
    /// サイドバーが見えていない間は git を起動しない。
    /// 誰も見ていない一覧のためにノートの電池を使いたくない
    private var collecting = false

    init() {
        reloadRecords()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit { pollTimer?.invalidate() }

    /// ID から台帳の1件を引く。View はここを通す
    func record(id: String) -> TaskRecord? {
        records.first { $0.id == id }
    }

    /// サイドバーの表示が切り替わったときに呼ぶ。
    func setCollecting(_ on: Bool) {
        guard collecting != on else { return }
        collecting = on
        if on { recount() }
    }

    /// いま見ているタブが変わったときに呼ぶ。
    func setFocused(_ session: String?) {
        guard focusedSession != session else { return }
        focusedSession = session
    }

    /// タブ番号の顔ぶれが変わったときに呼ぶ。
    func setTabNumbers(_ numbers: [String: Int]) {
        guard tabNumbers != numbers else { return }
        tabNumbers = numbers
    }

    /// いま見ているタブの現在地が変わったときに呼ぶ。
    ///
    /// リポジトリ本体を出すには git を起こすので、同じ場所は二度引かない
    /// (タブを行き来するだけで毎回起こすことになる)。
    func setCurrentDirectory(_ path: String?) {
        pendingDirectory = path
        guard let path else { apply(repo: nil); return }
        if let known = repoOfDirectory[path],
           known.origin.repository != nil || Date().timeIntervalSince(known.at) < outsideAnswerTTL {
            apply(repo: known.origin.repository)
            return
        }
        Task.detached(priority: .utility) {
            let top = GitClient.toplevel(from: path)
            let repo = top.isEmpty ? nil : (GitClient.mainWorktree(from: top) ?? top)
            await MainActor.run {
                self.remember(path, as: repo.map(DirectoryOrigin.repository) ?? .outside)
                // **遅れて届いた答えは捨てる。** 聞いたときの場所から既に移っていれば、
                // それを当てると別のリポジトリの worktree が並ぶ
                guard self.pendingDirectory == path else { return }
                self.apply(repo: repo)
            }
        }
    }

    private func remember(_ path: String, as origin: DirectoryOrigin) {
        if repoOfDirectory[path] == nil { directoryOrder.append(path) }
        repoOfDirectory[path] = (origin, Date())
        while directoryOrder.count > directoryCacheLimit {
            repoOfDirectory.removeValue(forKey: directoryOrder.removeFirst())
        }
    }

    private func apply(repo: String?) {
        guard currentRepo != repo else { return }
        currentRepo = repo
        // 立ち寄った先を少しだけ覚えておく。台帳が覚えているのは
        // 「エージェントを動かしたことのあるリポジトリ」だけなので、そうでない場所は
        // 現在地から外れた瞬間に数える対象から消える。タブを行き来するたびに
        // 見出しが消えたり出たりするので、直近の分は持ち回る
        // (並べるかどうかは、どのみちタブが開いているかで絞られる)
        if let repo {
            visited.removeAll { $0 == repo }
            visited.insert(repo, at: 0)
            if visited.count > 10 { visited.removeLast(visited.count - 10) }
        }
        // 場所が変わった瞬間に見たいので、次の周期を待たずに数え直す。
        // 覚えている顔ぶれも捨てて、必ず数え直す側に倒す
        lastWorktreeCount = .distantPast
        countedPlaces = []
        if collecting { recount() }
    }

    /// 一覧から1件外す。サイドバーの閉じるボタンから呼ばれる。
    ///
    /// 台帳を読み直す前に手元の一覧からも落とす。読み直しは git を起動するので
    /// 数百ミリ秒かかることがあり、押したのに消えない時間ができてしまう。
    func forget(id: String) {
        do {
            try ForgetTask.run(id: id)
        } catch {
            return  // 既に消えているなど。台帳が正なので何もしない
        }
        tasks.removeAll { $0.id == id }
        refreshNow()
    }

    /// 要確認から片付ける。サイドバーのチェックから呼ばれる。
    ///
    /// 押した瞬間に映るよう、git を起こさない経路 (`reapplied`) で先に差し替える。
    /// **判断は写さない。** 何がどう変わるかは台帳を読み直した結果から来るので、
    /// ここに「確認待ちは待機へ」のような写しを置かない
    func clearAttention(ids: [String]) {
        guard (try? ClearAttention.run(ids: ids)) == true else { return }
        reloadRecords()
        if let quick = CollectTasks.reapplied(tasks, records: records) { tasks = quick }
        // 差分と worktree は次の数え直しで揃える
        if collecting { recount() }
    }

    /// 台帳が外から変わったかもしれないときに呼ぶ (自分で書き換えた直後など)。
    func refreshNow() {
        reloadRecords()
        if collecting { recount() }
    }

    private func tick() {
        let modified = LedgerStore.lastModified()
        let changed = modified != lastModified
        if changed {
            lastModified = modified
            reloadRecords()
        }
        guard collecting else { return }
        // 台帳が変わっても、映せる分を映せたなら数え直しはしない。
        // ただし間隔のほうは止めない。ツールが立て続けに動いている間ずっと
        // 早い経路に乗り続けると、いちばん編集している最中に差分が固まってしまう
        let applied = changed && applyLedgerValues()
        if (changed && !applied) || Date().timeIntervalSince(lastRecount) >= recountInterval {
            recount()
        }
    }

    /// 台帳の変化のうち、git を起動せずに映せる分を先に映す。
    ///
    /// 「いま触っているツール」はツールのたびに変わる。ここで数え直していたら
    /// 1手ごとに worktree の数だけ git が起きるので、差分の数字は据え置いて
    /// 台帳の値だけ差し替える。
    ///
    /// - Returns: 映せたら true。数え直しが要るなら false
    ///   (顔ぶれか状態が変わったとき。状態が動くのはターンの切れ目なので、
    ///    そこでは数え直して差分を最新にする)
    private func applyLedgerValues() -> Bool {
        guard let quick = CollectTasks.reapplied(tasks, records: records) else { return false }
        let statusChanged = zip(tasks, quick).contains { $0.status != $1.status }
        guard !statusChanged else { return false }
        tasks = quick
        return true
    }

    /// 一覧最下部に出すレートリミット集約情報
    var rateLimitSummaries: [AgentQuotaSummary] {
        CollectTasks.summarizedRateLimits(tasks, persisted: agentRateLimits)
    }

    /// 一覧に出すリポジトリだけに絞る。
    ///
    /// 残すのは、タブが開いているか、最近見た場所として残すと決めたもの
    /// (`keep`)。**タブの有無だけでは足りない** —— それだけで絞ると、
    /// タブを閉じた瞬間にリポジトリが一覧から消えて、さっきまで居た場所へ
    /// 戻る道がそこで切れる。`keep` に入っていないリポジトリは、
    /// 今までどおりタブが開いているときだけ出る。
    ///
    /// タブの見分け方は2つ。どちらかに当たればそのリポジトリは「開いている」。
    ///
    /// 1. タブの現在地が、そのリポジトリのどこかの worktree の中にある。
    ///    リポジトリ本体のパスで見ないのは、worktree を本体の外に置く流儀があるから
    /// 2. そのタブで動いているセッションが、そのリポジトリのものである。
    ///    iTerm2 が答えるのはシェルの現在地なので、ホームで `claude` を起こして
    ///    そこから作業しているタブは、リポジトリではなくホームだと答える。
    ///    現在地だけで判じると、いま働いている場所ほど消えてしまう
    ///
    /// **聞けなかったとき (nil) は絞らない。** iTerm2 が一瞬答えなかっただけで
    /// 一覧から worktree がごっそり消えると、何が起きたのか分からない。
    nonisolated static func visible(
        _ groups: [CollectedRepoWorktrees],
        openTabs: [(session: String, directory: String)]?,
        sessions: [CollectedTask],
        keep: Set<String> = []) -> [CollectedRepoWorktrees] {
        guard let openTabs else { return groups }
        let directories = openTabs.map(\.directory)
        let liveTabs = Set(openTabs.map(\.session))
        // タブが生きているセッションの居場所。上の 2 に使う
        let occupied = Set(sessions
            .filter { liveTabs.contains($0.itermSession ?? "") }
            .map(\.worktree))

        return groups.filter { group in
            keep.contains(group.repo) || group.worktrees.contains { worktree in
                occupied.contains(worktree.path)
                    || directories.contains {
                        $0 == worktree.path || $0.hasPrefix(worktree.path + "/")
                    }
            }
        }
    }

    private func reloadRecords() {
        let ledger = LedgerStore.read()
        // iTerm2 のタブを持たないセッションは出さない。押しても元のタブへは戻れず、
        // 新しいタブが開くだけなので、一覧に並んでいても行き先が無い。
        // 台帳から消すわけではないので、CLI (proctor ls) には今までどおり出るし、
        // 死んだセッションの片付け (Reaper) も pid を見て続く。
        //
        // **絞る条件は recount() の itermOnly: true と揃えること。** 片方だけ変えると
        // applyLedgerValues() の照合 (顔ぶれが同じか) が常に外れ、台帳が動くたびに
        // worktree の数だけ git が起きる。エラーにはならないので気づけない
        // **変わっていないものは入れ直さない。** @Published は同じ値でも
        // 代入するだけで objectWillChange が飛び、SwiftUI が一覧をまるごと
        // 組み直す。台帳はツールが動くたびに触られるが、ここで見ている値まで
        // 毎回変わるわけではない (activity だけ動いた、など)
        let latest = ledger.tasks.filter(\.isItermManaged)
        if records != latest { records = latest }
        // 絞る前の顔ぶれを見る。端末の外で動いているセッションでも、
        // そこに乗られたら worktree は「誰もいない」ではなくなる
        sessionPlaces = Set(ledger.tasks.map(\.worktree))
        if agentRateLimits != ledger.agentRateLimits {
            agentRateLimits = ledger.agentRateLimits
        }
        // タプルの配列は Equatable にならないので、要素ごとに見る
        let counts = TaskStatus.counts(latest)
        if !summary.elementsEqual(counts, by: { $0 == $1 }) { summary = counts }
    }

    private func recount() {
        // **重ねては起こさない。** 台帳はツール1回ごとに動くので、前の数え直しが
        // 終わる前に次の番が来る。素直に走らせると worktree の数だけ起きる git が
        // 何組も重なって、いちばん動いている最中にいちばん重くなる。
        // 代わりに札を立てて、終わったところで1回だけ拾い直す。捨ててしまうと、
        // セッションや現在地が変わったのに古い結果で上書きされ、次の周期まで食い違う
        guard !recounting else { pendingRecount = true; return }
        recounting = true
        pendingRecount = false
        let now = Date()
        lastRecount = now
        // worktree のほうは自分の間隔を持つ。**見送った回は前回の値をそのまま残す**
        // (nil を入れると、数え直しのたびに一覧から worktree の行が消えて生え直す)。
        //
        // ただしセッションの居場所が変わったときは待たない。proctor から
        // worktree を開いてエージェントを立てた直後に、その worktree が
        // 「セッションがない」の側に残り続けるのがいちばん困る。
        // 見るのは居場所の顔ぶれだけなので、ツールが動くたびには走らない
        let placesChanged = sessionPlaces != countedPlaces
        let countWorktrees = placesChanged
            || now.timeIntervalSince(lastWorktreeCount) >= worktreeInterval
        if countWorktrees {
            lastWorktreeCount = now
            countedPlaces = sessionPlaces
        }
        // 数えるのは別スレッドなので、メインで読める値はここで写しておく。
        // iTerm2 への問い合わせ (AppleScript) もメインスレッドからでないと通らない。
        //
        // **台帳が覚えているだけのリポジトリまでは並べない。** 出すのは、タブが
        // 開いているものと、最近見たもの (visible の keep) だけ。全部見たいときは
        // CLI (proctor worktree ls --all) がある
        let here = visited
        let openTabs = countWorktrees ? ItermBridge.openTabs(interactive: false) : nil
        // git の起動を待つ間 UI を止めない。数え終わったらメインに戻して差し替える
        Task.detached(priority: .utility) {
            // 持ち主まで引くのはここだけ。Organization でまとめる見出しに要る。
            // 生き続けるプロセスなので、git が起きるのはリポジトリごとに一度きり。
            //
            // worktree を数える回だけ、絞る前の一覧を集める。一覧に出すのは
            // iTerm2 のタブを持つものだけだが、そこで絞ったものを突き合わせると、
            // 端末の外で動いているセッションが乗った worktree が
            // 「誰もいない」に見えてしまう (片付けてよい場所として並ぶ)。
            // とはいえ絞らない回はその分だけ git が増えるので、
            // 突き合わせが要らない回は今までどおり絞ってから数える
            let everything = CollectTasks.run(allRepos: true, itermOnly: !countWorktrees,
                                              withOrigin: true)
            // 読み切れなかった回は、そのまま映さずに前の値を残す。
            // git が一度答えなかっただけで行が消えると、何が起きたのか分からない
            let outcome: (worktrees: [CollectedRepoWorktrees]?,
                          kept: Set<String>?, incomplete: Bool) = {
                // **台帳を読むのは worktree を数える回だけ。** 数えない回は
                // visible を呼ばないので、残すかどうかの判断そのものが要らない。
                // LedgerStore.repos() は台帳 JSON を丸ごとデコードするので、
                // ここに置かずに毎回読むと、同じ Task.detached の中で
                // CollectTasks.run が既に1回読んでいるぶんと合わせて、
                // 10秒ごと (とツールが動くたび) にデコードが2回走ることになる
                guard countWorktrees else { return (nil, nil, false) }
                // 覚えているリポジトリはここで一度だけ読む。worktree の数え上げも
                // 「一覧に残すか」の判断も同じものを見るので、それぞれに読ませると
                // 同じ台帳を2回開くことになる
                let ledgerRepos = LedgerStore.repos()
                // 最後のタブを閉じても、しばらくは一覧に残しておくリポジトリ。
                // 読んだ台帳を使い回すだけなので、ここでは何も起きない
                let kept = CollectRecentRepos.run(repos: ledgerRepos)
                let counted = CollectWorktrees.runDetailed(allRepos: true, withOrigin: true,
                                                           tasks: everything,
                                                           repos: ledgerRepos, also: here)
                // worktree のほうが読めなくても、残す顔ぶれは分かっている。
                // 据え置きの一覧に対しても効くので、そちらは映してよい
                guard !counted.incomplete else { return (nil, kept, true) }
                return (TaskStore.visible(counted.groups, openTabs: openTabs,
                                          sessions: everything, keep: kept), kept, false)
            }()
            let collected = everything.filter(\.isItermManaged)
            await MainActor.run {
                self.recounting = false
                self.tasks = collected
                if let latest = outcome.worktrees, self.worktrees != latest {
                    self.worktrees = latest
                }
                // **変わっていないものは入れ直さない** (理由は reloadRecords と同じ)。
                // 同じ値の代入でも objectWillChange が飛び、10秒ごとに
                // 一覧がまるごと組み直される
                if let kept = outcome.kept, self.keptRepos != kept { self.keptRepos = kept }
                // 読めなかったぶんは次の周期を待たずに聞き直す
                if outcome.incomplete { self.lastWorktreeCount = .distantPast }
                if self.pendingRecount, self.collecting { self.recount() }
            }
        }
    }
}
