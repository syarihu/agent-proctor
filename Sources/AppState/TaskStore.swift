import Foundation
import Combine
import Model
import RepositoryLedger
import RepositoryGit
import UseCaseTask
import UseCaseWorktree
import UseCaseNotice
import UseCaseSession
import ItermBridge

/// 台帳の変更を監視し、UI 表示用のデータを配信する状態管理クラス。
///
/// View から Repository への直接依存を防ぐファサードの役割を持つ。
///
/// 負荷の異なる2段階の監視を行う:
/// - 台帳ファイルの更新時刻監視: stat システムコールのみで軽量。状態変化を検知して短周期で実行する。
/// - 一覧および差分の再集計: worktree ごとに git プロセスを起動するため負荷が高い。表示中のみ適応型の間隔で実行する。
///
/// 再集計の間隔は固定ではなく、直前の処理時間に基づいて動的に調整する（PaceRecounts）。
@MainActor
public final class TaskStore: ObservableObject {
    /// サイドバー表示中のみ更新される、git 差分を含めたタスク一覧
    @Published public private(set) var tasks: [CollectedTask] = []
    /// 台帳データそのもの（git を呼ばないため常に最新を保持可能）
    @Published public private(set) var records: [TaskRecord] = []
    /// メニューバー表示用の状態集計
    @Published public private(set) var summary: [(status: String, count: Int)] = []
    /// エージェント別のレートリミットキャッシュ
    @Published public private(set) var agentRateLimits: [String: AgentRateLimits] = [:]
    /// リポジトリごとの worktree 一覧（git プロセスを起動するため長周期で更新）
    @Published public private(set) var worktrees: [CollectedRepoWorktrees] = []
    /// セッション終了後も一覧に保持するリポジトリ（直近アクセス履歴）
    @Published public private(set) var keptRepos: Set<String> = []
    /// 現在フォーカスされている iTerm2 セッション
    @Published public private(set) var focusedSession: String?
    /// 現在アクティブなタブが所属するリポジトリ本体のパス
    @Published public private(set) var currentRepo: String?
    /// セッション guid ごとの iTerm2 タブ番号（⌘N の N）。
    /// タブの開閉や並べ替えのたびに頻繁に変動するため、台帳には永続化せずオンメモリで保持する。
    @Published public private(set) var tabNumbers: [String: Int] = [:]

    /// 台帳更新時刻のポーリング間隔
    private let pollInterval: TimeInterval = 0.5
    /// セッション差分再集計の間隔（処理時間から動的に算出）
    private var sessionPace = PaceRecounts.sessions
    /// worktree 再集計の間隔
    private var worktreePace = PaceRecounts.worktrees

    private var recountInterval: TimeInterval { sessionPace.interval }
    private var worktreeInterval: TimeInterval { worktreePace.interval }

    private var pollTimer: Timer?
    private var lastModified: Date?
    private var lastRecount = Date.distantPast
    private var lastWorktreeCount = Date.distantPast
    /// ファイル変更監視
    private let watcher = WorktreeWatcher()
    /// 最後に差分キャッシュを全破棄した時刻
    private var lastForgetAll = Date.distantPast
    /// 差分キャッシュの定期全破棄間隔（FSEvents の通知取りこぼしに対するフォールバック）
    private let forgetAllInterval: TimeInterval = 300
    /// 最後に経過時間のみを更新した時刻
    private var lastElapsed = Date.distantPast
    /// ディレクトリ調査結果のキャッシュ表現
    private enum DirectoryOrigin {
        case repository(String), outside
        var repository: String? {
            if case .repository(let path) = self { return path }
            return nil
        }
    }
    /// ディレクトリパスごとの git リポジトリ判定キャッシュ
    private var repoOfDirectory: [String: (origin: DirectoryOrigin, at: Date)] = [:]
    /// 「git リポジトリ外」判定のキャッシュ有効期間（一時的なコマンド失敗による誤判定を避けるためTTLを設ける）
    private let outsideAnswerTTL: TimeInterval = 60
    private var directoryOrder: [String] = []
    private let directoryCacheLimit = 200
    /// 最新の問い合わせディレクトリパス（非同期レスポンスの順序逆転対策）
    private var pendingDirectory: String?
    /// 最近アクセスしたリポジトリ一覧（最大10件）
    private var visited: [String] = []
    /// 現在セッションが存在するディレクトリ群
    private var sessionPlaces: Set<String> = []
    /// 前回 worktree を集計した際のセッションディレクトリ群
    private var countedPlaces: Set<String> = []
    /// 再集計処理が実行中かどうかのフラグ（多重実行防止）
    private var recounting = false
    /// 再集計の要求種別
    private enum RecountReason {
        /// ユーザー操作や構成変更による即時再集計
        case urgent
        /// 定期ポーリングによる再集計
        case periodic
    }
    /// 実行中に蓄積された次回の再集計要求（urgent を優先保持）
    private var pendingRecount: RecountReason?
    /// サイドバーが表示されているかどうか（非表示時は git 処理を停止して負荷を抑制）
    private var collecting = false
    /// 変更差分を集計するかどうかの判定プロバイダ
    public var wantsDiff: () -> Bool = { true }

    public init() {
        reloadRecords()
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) {
            [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    deinit { pollTimer?.invalidate() }

    /// ID から台帳の1件を引く。View はここを通す
    public func record(id: String) -> TaskRecord? {
        records.first { $0.id == id }
    }

    /// サイドバーの表示が切り替わったときに呼ぶ。
    public func setCollecting(_ on: Bool) {
        guard collecting != on else { return }
        collecting = on
        if on {
            // 見ていなかった間の変化は報せが来ていない。覚えた数字は全部捨てる
            // (次の recount が forgetAll まで通る)
            lastForgetAll = .distantPast
            recount(reason: .urgent)
        } else {
            // 誰も見ていない一覧のために見張らない。畳むと覚えている場所も
            // 消えるので、次に開いたときの watch はちゃんと張り直しになる
            watcher.stop()
        }
    }

    /// いま見ているタブが変わったときに呼ぶ。
    public func setFocused(_ session: String?) {
        guard focusedSession != session else { return }
        focusedSession = session
    }

    /// タブ番号の対応関係が変化した際に呼び出す
    public func setTabNumbers(_ numbers: [String: Int]) {
        guard tabNumbers != numbers else { return }
        tabNumbers = numbers
    }

    /// いま見ているタブの現在地が変わったときに呼ぶ。
    ///
    /// リポジトリ本体を出すには git を起こすので、同じ場所は二度引かない
    /// (タブを行き来するだけで毎回起こすことになる)。
    public func setCurrentDirectory(_ path: String?) {
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
                // 非同期取得中に現在地が変わっていた場合は古い取得結果を破棄する
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
        // 直近訪れたリポジトリを保持し、タブ非フォーカス時の即時非表示を防ぐ
        if let repo {
            visited.removeAll { $0 == repo }
            visited.insert(repo, at: 0)
            if visited.count > 10 { visited.removeLast(visited.count - 10) }
        }
        // ディレクトリ変更時は直近の集計キャッシュを無効化し即時再集計を行う
        lastWorktreeCount = .distantPast
        countedPlaces = []
        if collecting { recount(reason: .urgent) }
    }

    /// 一覧から1件除外する（サイドバーの閉じるボタン等から呼び出し）。
    ///
    /// 台帳更新と git 読み直しによる遅延中に UI が残存するのを防ぐため、
    /// ローカルの tasks 配列から即座に削除した上でリフレッシュを行う。
    public func forget(id: String) {
        do {
            try ForgetTask.forget(id: id)
        } catch {
            return  // 既に消えている等。台帳が正なので何もしない
        }
        tasks.removeAll { $0.id == id }
        refreshNow()
    }

    /// 要確認状態を解除する（サイドバーのチェックボタンから呼び出し）。
    ///
    /// UI へ即時反映させるため、git を起動しない経路（reapplied）で先行適用する。
    public func clearAttention(ids: [String]) {
        guard (try? ClearAttention.clear(ids: ids)) == true else { return }
        reloadRecords()
        if let quick = CollectTasks.reapplied(tasks, records: records) { tasks = quick }
        if collecting { recount(reason: .urgent) }
    }

    /// 台帳が外部から更新された可能性がある場合に呼び出す（自身での更新直後など）。
    public func refreshNow() {
        reloadRecords()
        if collecting { recount(reason: .urgent) }
    }

    /// 「変更を数える」設定の切り替え通知。
    /// worktree の次回更新時刻をリセットし、即時再集計を行う。
    public func countingSettingChanged() {
        lastWorktreeCount = .distantPast
        if collecting { recount(reason: .urgent) }
    }

    /// 定期ポーリング時に再集計を実行すべきかどうか。
    /// ファイル変更が検知された場合、または定期キャッシュ全破棄間隔に達した場合のみ実行する。
    private var worthRecounting: Bool {
        watcher.hasChanged
            || Date().timeIntervalSince(lastForgetAll) >= forgetAllInterval
    }

    private func tick() {
        let modified = LedgerStore.lastModified()
        let changed = modified != lastModified
        if changed {
            lastModified = modified
            reloadRecords()
        }
        guard collecting else { return }
        // 高負荷環境（sessionPace.isExpensive）では、ターンの切れ目ごとの連続 git 起動を防ぐため
        // 状態変更時も差分再集計を行わず quick path（reapplied）で反映する
        let applied = changed
            && applyLedgerValues(includingStatusChanges: sessionPace.isExpensive)
        if changed && !applied {
            // タスク構成が変化した場合は差分情報を新規取得する必要があるため即時再集計する
            recount(reason: .urgent)
        } else if Date().timeIntervalSince(lastRecount) >= recountInterval {
            if worthRecounting {
                recount(reason: .periodic)
            } else if Date().timeIntervalSince(lastElapsed) >= recountInterval {
                refreshElapsed()
            }
        }
    }

    /// git プロセスを起動せず、経過時間などの時刻由来の表示のみを更新する。
    private func refreshElapsed() {
        lastElapsed = Date()
        guard let quick = CollectTasks.reapplied(tasks, records: records) else { return }
        tasks = quick
    }

    /// 台帳の変更内容のうち、git を起動せずに反映可能な項目を先行適用する。
    private func applyLedgerValues(includingStatusChanges: Bool) -> Bool {
        guard let quick = CollectTasks.reapplied(tasks, records: records) else { return false }
        if !includingStatusChanges {
            let statusChanged = zip(tasks, quick).contains { $0.status != $1.status }
            guard !statusChanged else { return false }
        }
        tasks = quick
        return true
    }

    /// 測った時間を秒で返す。
    nonisolated static func seconds(since start: ContinuousClock.Instant) -> TimeInterval {
        let elapsed = ContinuousClock.now - start
        return TimeInterval(elapsed.components.seconds)
            + TimeInterval(elapsed.components.attoseconds) / 1e18
    }

    /// 一覧最下部に出すレートリミット集約情報
    public var rateLimitSummaries: [AgentQuotaSummary] {
        CollectTasks.summarizedRateLimits(tasks, persisted: agentRateLimits)
    }

    /// 一覧に出すリポジトリだけに絞る。
    ///
    /// タブを閉じた直後にリポジトリが一覧から消失するのを防ぐため、最近訪れたリポジトリ（keep）も含めて保持する。
    ///
    /// タブの見分け方は2つ。どちらかに当たればそのリポジトリは「開いている」。
    ///
    /// 1. タブの現在地が、そのリポジトリのどこかの worktree の中にある。
    /// 2. そのタブで動いているセッションが、そのリポジトリのものである。
    ///
    /// iTerm2 から情報が取得できなかった場合（nil）は誤った非表示を防ぐため全グループを維持する。
    nonisolated static func visible(
        _ groups: [CollectedRepoWorktrees],
        openTabs: [(session: String, directory: String)]?,
        sessions: [CollectedTask],
        keep: Set<String> = []) -> [CollectedRepoWorktrees] {
        guard let openTabs else { return groups }
        let directories = openTabs.map(\.directory)
        let liveTabs = Set(openTabs.map(\.session))
        // タブが生存しているセッションの作業ディレクトリ
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
        // iTerm2 管理外のセッションは一覧に表示しない（遷移先タブが存在しないため）。
        // recount() の itermOnly 絞り込み条件と一致させる必要がある（一致しないと applyLedgerValues の照合が常に失敗する）。
        let latest = ledger.tasks.filter(\.isItermManaged)
        // 値が同一の場合は代入をスキップし、不要な objectWillChange 発火による SwiftUI 再描画を防ぐ
        if records != latest { records = latest }
        // 端末外で動作中のセッションも含め、セッションが存在する全作業ツリーを把握する
        sessionPlaces = Set(ledger.tasks.map(\.worktree))
        if agentRateLimits != ledger.agentRateLimits {
            agentRateLimits = ledger.agentRateLimits
        }
        let counts = TaskStatus.counts(latest)
        if !summary.elementsEqual(counts, by: { $0 == $1 }) { summary = counts }
    }

    private func recount(reason: RecountReason) {
        // 多重実行を防止する。実行中に届いた要求は pendingRecount に退避し、完了後に再評価する
        guard !recounting else {
            if reason == .urgent || pendingRecount == nil { pendingRecount = reason }
            return
        }
        recounting = true
        pendingRecount = nil
        let now = Date()
        lastRecount = now
        // 再集計前にファイル変更差分を取得し、該当パスのキャッシュを無効化する
        if now.timeIntervalSince(lastForgetAll) >= forgetAllInterval {
            lastForgetAll = now
            _ = watcher.takeChanged()
            CountChanges.forgetAll()
        } else {
            CountChanges.invalidate(watcher.takeChanged())
        }
        watcher.watch(watchRoots())

        // worktree 一覧の更新要否判定（セッションの作業ディレクトリの変化、または更新間隔経過時）
        let placesChanged = sessionPlaces != countedPlaces
        let countWorktrees = placesChanged
            || now.timeIntervalSince(lastWorktreeCount) >= worktreeInterval
        if countWorktrees {
            lastWorktreeCount = now
            countedPlaces = sessionPlaces
        }

        let here = visited
        let openTabs = countWorktrees ? ItermBridge.openTabs(interactive: false) : nil
        let countDiff = wantsDiff()
        let knownRepos = Set(records.map(\.repo))

        // git 処理はバックグラウンドスレッドで実行し、UI の応答性を維持する
        Task.detached(priority: .utility) {
            // worktree 集計時のみ台帳リポジトリ情報を取得する（不要な JSON デコードの重複を回避）
            let ledgerRepos = countWorktrees ? LedgerStore.repos() : nil

            // リポジトリ Origin の解決結果をキャッシュしておく。
            // 初回解決（git remote）の遅延が sessionPace の処理時間計測に混入し、
            // ポーリング間隔が過大に伸びるのを防ぐため、計測区間の前に実行する。
            var warm = knownRepos
            if let ledgerRepos { warm.formUnion(ledgerRepos.keys) }
            warm.formUnion(here)
            for repo in warm { _ = ResolveRepoOrigin.resolve(repo: repo) }

            // 所要時間を計測してポーリング間隔の適応制御（sessionPace）に反映する。
            // NTP 同期等による時刻変動の影響を避けるため ContinuousClock を使用する
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
            let everything = CollectTasks.collect(allRepos: true, itermOnly: !countWorktrees,
                                                  withOrigin: true, countDiff: countDiff)
            let sessionSeconds = TaskStore.seconds(since: sessionStart)
            // 読み切れなかった回は、そのまま映さずに前の値を残す。
            // git が一度答えなかっただけで行が消えると、何が起きたのか分からない。
            //
            // 処理時間はセッション集計と worktree 集計で個別に計測する。
            // worktree 未集計時は nil を設定し、0秒として記録して間隔が不当に短縮されるのを防ぐ
            let outcome: (worktrees: [CollectedRepoWorktrees]?, kept: Set<String>?,
                          incomplete: Bool, seconds: TimeInterval?) = {
                guard countWorktrees, let ledgerRepos else { return (nil, nil, false, nil) }
                let kept = CollectRecentRepos.collect(repos: ledgerRepos)
                let start = ContinuousClock.now
                let counted = CollectWorktrees.collect(allRepos: true, withOrigin: true,
                                                       countDiff: countDiff,
                                                       tasks: everything,
                                                       repos: ledgerRepos, also: here)
                let seconds = TaskStore.seconds(since: start)
                guard !counted.incomplete else { return (nil, kept, true, seconds) }
                return (TaskStore.visible(counted.groups, openTabs: openTabs,
                                          sessions: everything, keep: kept),
                        kept, false, seconds)
            }()
            let collected = everything.filter(\.isItermManaged)
            await MainActor.run {
                self.recounting = false
                // worktree を同時に集計した回はセッション側も非絞り込み（itermOnly: false）となり
                // 通常より処理時間が長くなるため、observe ではなく decay（減衰）を行う。
                // worktree を数えない通常回のみ実測値を observe に反映する。
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
                // 等価な場合は代入をスキップし、不要な SwiftUI 再描画を防ぐ
                if let kept = outcome.kept, self.keptRepos != kept { self.keptRepos = kept }
                if outcome.incomplete { self.lastWorktreeCount = .distantPast }
                let pending = self.pendingRecount
                self.pendingRecount = nil
                if pending == .urgent, self.collecting { self.recount(reason: .urgent) }
            }
        }
    }

    /// ファイル変更監視対象のパスと、変更時にキャッシュ無効化する対象パスの対応マップを構築する。
    ///
    /// 各作業ツリーのほか、連結 worktree の git 管理ディレクトリ（adminDirectory）も監視対象に含める
    /// （コミット実行時に作業ツリー側のファイルが動かない場合でも差分更新を検知するため）。
    private func watchRoots() -> [String: String] {
        var roots: [String: String] = [:]
        for repo in records.map(\.repo) { roots[repo] = repo }
        for place in sessionPlaces { roots[place] = place }
        for group in worktrees {
            roots[group.repo] = group.repo
            for worktree in group.worktrees { roots[worktree.path] = worktree.path }
        }
        for worktree in Set(roots.values) {
            guard let admin = GitClient.adminDirectory(of: worktree) else { continue }
            roots[admin] = worktree
        }
        return roots.filter { FileManager.default.fileExists(atPath: $0.key) }
    }
}
