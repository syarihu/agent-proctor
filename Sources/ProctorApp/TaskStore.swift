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
///
/// その周期は固定ではなく、**数え直しにかかった時間から決める** (`PaceRecounts`)。
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
    /// 台帳が変わらなくても数え直す間隔。かかった時間から決まる (`PaceRecounts`)
    private var sessionPace = PaceRecounts.sessions
    /// worktree を数え直す間隔。一覧の数え直しよりさらに長い。
    /// worktree は作られたり消えたりが分単位の出来事なのに、数えるのは1件につき
    /// git を数回。セッションの差分と同じ速さで回すと、居るだけで git が鳴り続ける
    private var worktreePace = PaceRecounts.worktrees

    private var recountInterval: TimeInterval { sessionPace.interval }
    private var worktreeInterval: TimeInterval { worktreePace.interval }

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
    /// 数え直しを求めた理由。
    ///
    /// **周期を伸ばしても、ここを塞がないと git は鳴り続ける。** 走っている
    /// 最中に台帳が動くたびに札が立ち、終わった瞬間にもう一度走るので、
    /// 200秒の周期にしても実際には数え直しが数珠つなぎになる
    private enum RecountReason {
        /// 人が押した、あるいは顔ぶれ・現在地が変わった。**待たせない**
        case urgent
        /// 周期が来ただけ。走っている最中に重なったなら捨ててよい
        /// (lastRecount は数え直しの**開始**時刻なので、次はどのみち
        ///  完了から「間隔 − 所要時間」後に tick() が拾う)
        case periodic
    }
    /// 走っている最中に来た数え直しの求め。**強いほうを残す**
    private var pendingRecount: RecountReason?
    /// サイドバーが見えていない間は git を起動しない。
    /// 誰も見ていない一覧のためにノートの電池を使いたくない
    private var collecting = false
    /// 差分を数えてよいか。**覚え込まずに毎回聞く。**
    ///
    /// 設定は途中で変わるので、起動時の答えを持ち回ると次の起動まで効かない
    /// (FocusWatcher の wantsTabNumbers や seenPolicy と同じ形)。
    /// 既定を true にしてあるので、繋ぎ忘れても今までどおり数える
    var wantsDiff: () -> Bool = { true }

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
        if on { recount(reason: .urgent) }
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
        if collecting { recount(reason: .urgent) }
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
        if collecting { recount(reason: .urgent) }
    }

    /// 台帳が外から変わったかもしれないときに呼ぶ (自分で書き換えた直後など)。
    func refreshNow() {
        reloadRecords()
        if collecting { recount(reason: .urgent) }
    }

    /// 「変更を数える」の設定が切り替わったときに呼ぶ。
    ///
    /// **worktree の周期を捨ててから数え直す。** `refreshNow()` では足りない —
    /// あちらは `countWorktrees` の判断に触らないので、急ぎで数え直しても
    /// worktree の側は自前の周期 (最大600秒) を待つ。セッション行の数字だけ
    /// その場で消えて、worktree の側は古い判定を出し続けることになる。
    ///
    /// 逆に `refreshNow()` のほうへ入れてもいけない。あちらは台帳が書き換わる
    /// たびに呼ばれるので、そこに置くと worktree の全走査がその都度走る。
    ///
    /// **呼ぶ側は一拍置くこと** (`main.swift` の debounce)。ここを通ると
    /// 数え直しは必ず worktree を数える道に入り、その道はメインスレッドで
    /// iTerm2 に AppleScript で問い合わせるので、押した直後だとスイッチが固まる。
    ///
    /// `countedPlaces` は捨てない。**あれが覚えているのはセッションの顔ぶれ**で、
    /// 設定を切り替えても顔ぶれは変わっていない
    func countingSettingChanged() {
        lastWorktreeCount = .distantPast
        if collecting { recount(reason: .urgent) }
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
        // 早い経路に乗り続けると、いちばん編集している最中に差分が固まってしまう。
        //
        // **数えるのが高いと分かった場所では、状態が動いても数え直さない。**
        // そうしないと、周期をいくら伸ばしてもターンの切れ目ごとに git が起きて
        // 元の木阿弥になる。状態の色は quick path (CollectTasks.reapplied) が
        // 台帳から運ぶので遅れない。据え置きになるのは差分の数字だけ
        let applied = changed
            && applyLedgerValues(includingStatusChanges: sessionPace.isExpensive)
        if changed && !applied {
            // quick path に乗れなかった。**顔ぶれが変わっているので待たせない** —
            // 新しい行には持ち越せる差分が無く、周期を待つと数字が出ないままになる
            recount(reason: .urgent)
        } else if Date().timeIntervalSince(lastRecount) >= recountInterval {
            recount(reason: .periodic)
        }
    }

    /// 台帳の変化のうち、git を起動せずに映せる分を先に映す。
    ///
    /// 「いま触っているツール」はツールのたびに変わる。ここで数え直していたら
    /// 1手ごとに worktree の数だけ git が起きるので、差分の数字は据え置いて
    /// 台帳の値だけ差し替える。
    ///
    /// - Parameter includingStatusChanges: 状態が動いた回もここで映してしまう。
    ///   **数えるのが高いと分かった場所でだけ true にする。** 状態が動くのは
    ///   ターンの切れ目なので、平時はそこで数え直して差分を最新にしたい
    ///   (速いリポジトリの振る舞いは今までどおり)。ただし1回に数秒かかる場所では、
    ///   ターンのたびに数え直していると周期を伸ばした意味が無くなる。
    ///   そちらでは状態だけ先に映して、差分は次の周期に回す
    /// - Returns: 映せたら true。数え直しが要るなら false
    ///   (顔ぶれが変わったとき、または状態が動いて上を false にしているとき)
    private func applyLedgerValues(includingStatusChanges: Bool) -> Bool {
        guard let quick = CollectTasks.reapplied(tasks, records: records) else { return false }
        if !includingStatusChanges {
            let statusChanged = zip(tasks, quick).contains { $0.status != $1.status }
            guard !statusChanged else { return false }
        }
        tasks = quick
        return true
    }

    /// 測った時間を秒で返す。Duration は attosecond まで持つので、
    /// 秒とその端数を足して TimeInterval に均す
    nonisolated static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1e18
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

    private func recount(reason: RecountReason) {
        // **重ねては起こさない。** 台帳はツール1回ごとに動くので、前の数え直しが
        // 終わる前に次の番が来る。素直に走らせると worktree の数だけ起きる git が
        // 何組も重なって、いちばん動いている最中にいちばん重くなる。
        // 代わりに札を立てて、終わったところで1回だけ拾い直す。捨ててしまうと、
        // セッションや現在地が変わったのに古い結果で上書きされ、次の周期まで食い違う
        guard !recounting else {
            // **強いほうを残す。** 周期の求めが先に立っていても、
            // 人が押したのなら急ぐ側で上書きする
            if reason == .urgent || pendingRecount == nil { pendingRecount = reason }
            return
        }
        recounting = true
        pendingRecount = nil
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
        // 設定も同じくここで読む。Appearance は @MainActor なので、
        // detached の中からは触れない
        let countDiff = wantsDiff()
        // 持ち主を先に引いておく相手 (下の「温める」を見よ)。**手元にある顔ぶれから
        // 採る。** 台帳を読み直せば正確だが、そのために JSON を丸ごとデコードするのは
        // 温めるためだけの支払いになる。絞る回の CollectTasks.run が見るのは
        // ここと同じ (どちらも isItermManaged で絞った顔ぶれ) なので、これで足りる
        let knownRepos = Set(records.map(\.repo))
        // git の起動を待つ間 UI を止めない。数え終わったらメインに戻して差し替える
        Task.detached(priority: .utility) {
            // 覚えているリポジトリはここで一度だけ読む。worktree の数え上げも
            // 「一覧に残すか」の判断も同じものを見るので、それぞれに読ませると
            // 同じ台帳を2回開くことになる。
            //
            // **読むのは worktree を数える回だけ。** 数えない回は visible を
            // 呼ばないので、残すかどうかの判断そのものが要らない。
            // LedgerStore.repos() は台帳 JSON を丸ごとデコードするので、
            // 毎回読むと、同じ Task.detached の中で CollectTasks.run が既に
            // 1回読んでいるぶんと合わせて、10秒ごと (とツールが動くたび) に
            // デコードが2回走ることになる。
            //
            // **測り始める前に読む。** worktree を数える回に必ず払う固定費であって、
            // 「数えるのがどれだけ高いか」の一部ではない。
            //
            // **`ledgerRepos != nil` と `countWorktrees` は同じことを指す。**
            // 読み手が2つ (下の outcome と、その前の「温める」) に増えているので、
            // どちらかを countWorktrees と無関係に読める形へ広げないこと。
            // 広げた瞬間、数えない回でも台帳のデコードが走り、同じ Task.detached の
            // 中で CollectTasks.run が読むぶんと合わせて、10秒ごと
            // (とツールが動くたび) に同じ台帳を2回デコードすることになる
            let ledgerRepos = countWorktrees ? LedgerStore.repos() : nil

            // **持ち主の解決も測る前に済ませておく。** ResolveRepoOrigin は
            // 答えをプロセスの中に覚えるので高いのは初めて見るリポジトリの回だけ
            // だが、`observe` は上がるときだけ即座に効くので、その1回が
            // `smoothed` に焼き付いて周期が伸びたまま戻らなくなる
            // (台帳の全リポジトリぶんの git remote は、15件もあれば数秒になる)。
            //
            // **初回の観測を捨てるだけでは足りない。** 台帳に新しいリポジトリが
            // 加わるたびに同じ支払いが起きるので、そのたびに再発する。
            // ここで温めておけば、下で測る区間はいつも「覚えている答えを引くだけ」
            // に揃う。台帳を読んだ回はそちらも混ぜる —— **セッションの無いリポジトリの
            // 持ち主を引くのは CollectWorktrees** で、それは worktree の側の
            // 計測区間の中にあるため
            var warm = knownRepos
            if let ledgerRepos { warm.formUnion(ledgerRepos.keys) }
            // 立ち寄っただけの場所も混ぜる。**台帳にはまだ載っていない** ——
            // エージェントを一度も動かしていないリポジトリを拾うのが visited の
            // 役目なので、ここを外すと「今いる場所」がいちばん温まらない。
            // 実体の無いパスを渡しても、引けなかったことごと覚えるので git は1回きり
            warm.formUnion(here)
            for repo in warm { _ = ResolveRepoOrigin.run(repo: repo) }

            // **かかった時間を測って、次までの間隔に食わせる。**
            // 時計は ContinuousClock を使う。Date は NTP で飛ぶので、
            // 時刻が直された回に出鱈目な所要時間を覚えてしまう
            let sessionStart = ContinuousClock.now
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
                                              withOrigin: true, countDiff: countDiff)
            let sessionSeconds = TaskStore.seconds(since: sessionStart)
            // 読み切れなかった回は、そのまま映さずに前の値を残す。
            // git が一度答えなかっただけで行が消えると、何が起きたのか分からない。
            //
            // **時間はセッションのぶんと別々に測る。** それぞれ自分の間隔を持っているので、
            // 混ぜると片方の重さでもう片方まで伸びる。
            // 数えなかった回は nil。0 秒として食わせると、見送っただけの回で
            // 間隔が下限まで戻ってしまう
            let outcome: (worktrees: [CollectedRepoWorktrees]?, kept: Set<String>?,
                          incomplete: Bool, seconds: TimeInterval?) = {
                // 台帳を読んでいない回 = worktree を数えない回 (上を見よ)
                guard countWorktrees, let ledgerRepos else { return (nil, nil, false, nil) }
                // 最後のタブを閉じても、しばらくは一覧に残しておくリポジトリ。
                // 読んだ台帳を使い回すだけなので、ここでは何も起きない
                // (measure の外に置いてあるのはそのため)
                let kept = CollectRecentRepos.run(repos: ledgerRepos)
                let start = ContinuousClock.now
                let counted = CollectWorktrees.runDetailed(allRepos: true, withOrigin: true,
                                                           countDiff: countDiff,
                                                           tasks: everything,
                                                           repos: ledgerRepos, also: here)
                // 読み切れなかった回も、git を待った時間は同じだけかかっている
                let seconds = TaskStore.seconds(since: start)
                // worktree のほうが読めなくても、残す顔ぶれは分かっている。
                // 据え置きの一覧に対しても効くので、そちらは映してよい
                guard !counted.incomplete else { return (nil, kept, true, seconds) }
                return (TaskStore.visible(counted.groups, openTabs: openTabs,
                                          sessions: everything, keep: kept),
                        kept, false, seconds)
            }()
            let collected = everything.filter(\.isItermManaged)
            await MainActor.run {
                self.recounting = false
                // **設定で切ってあっても測り続ける。** 切ってあれば実測は
                // 小さくなるので間隔は自然と下限へ戻り、オンに戻すと重い回が
                // 1回だけ走ってそこでまた伸びる。
                //
                // ただし worktree を数えた回は食わせない。その回だけ
                // セッション側も絞らずに集める (itermOnly: false) ので、
                // 系統的に高い。6回に1回しか起きない費用でセッションの周期まで
                // 伸ばすと、上の「混ぜると片方の重さでもう片方まで伸びる」が
                // セッションの内側で起きることになる
                //
                // **食わせない回は、代わりに古びさせる (decay)。** 据え置きにすると、
                // セッションの周期が worktree の周期 (下限60秒) を追い越した時点で
                // どの回も「worktree を数える回」になり、**セッション側の実測を
                // 二度と採れなくなる**。一度たまたま4秒かかっただけで 80秒間隔に
                // 貼り付き、立ち上げ直すまで戻らない (`isExpensive` も貼り付くので、
                // ターンの切れ目で差分を数え直す道まで閉じたままになる)。
                // 減らしていけば数回で 60秒を割り、そこで実測の回が戻ってくる
                if !countWorktrees {
                    self.sessionPace.observe(sessionSeconds)
                } else {
                    self.sessionPace.decay()
                }
                if let seconds = outcome.seconds { self.worktreePace.observe(seconds) }
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
                // **拾い直すのは急ぎの求めだけ。** 周期の求めまで拾うと、
                // 台帳が動くたびに数え直しが数珠つなぎになって間隔が効かない。
                // 捨てたぶんは tick() が周期で拾う
                let pending = self.pendingRecount
                self.pendingRecount = nil
                if pending == .urgent, self.collecting { self.recount(reason: .urgent) }
            }
        }
    }
}
