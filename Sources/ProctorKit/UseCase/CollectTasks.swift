import Foundation

/// 台帳に動的な情報を足して返す。表示側の共通の入り口。
///
/// CLI の表もサイドバーもメニューバーもこの戻り値を整形するだけにする。
/// 集計をここに閉じ込めることで、表示側にロジックが漏れるのを防ぐ。
/// 集計を足したくなったらここに書く。
public enum CollectTasks {
    /// - Parameters:
    ///   - repo: 指定したリポジトリだけに絞る。allRepos が true なら無視される
    ///   - allRepos: 全リポジトリを対象にする
    ///   - itermOnly: iTerm2 のタブとして開き直せるものだけに絞る。
    ///     既定は false。台帳に載っているものをそのまま見せるのが CLI の役目で、
    ///     絞るかどうかは「押したら開けるか」を気にする側 (アプリ) の都合
    ///   - withOrigin: リポジトリの持ち主 (remote) まで調べる。
    ///     **既定は false。要る人だけが払う。** 持ち主を引くには
    ///     リポジトリごとに git をもう1回起こす必要があり、remote が
    ///     `origin` でなければ2回、1つも無ければやはり2回になる。
    ///     答えはプロセスの中に覚えるので、生き続けるアプリでは最初の1回で済むが、
    ///     **一回きりで終わる CLI では毎回が「最初の1回」**になる。
    ///     `proctor ls` の表は持ち主を出さないので、既定では引かない
    public static func run(repo: String? = nil, allRepos: Bool = false,
                           itermOnly: Bool = false,
                           withOrigin: Bool = false) -> [CollectedTask] {
        var records = LedgerStore.tasks()
        if !allRepos, let repo {
            records = records.filter { $0.repo == repo }
        }
        if itermOnly {
            records = records.filter(\.isItermManaged)
        }

        let now = Int(Date().timeIntervalSince1970)
        return ordered(records).map { record in
            let exists = FileManager.default.fileExists(atPath: record.worktree)
            return CollectedTask(
                record: record,
                repoName: URL(fileURLWithPath: record.repo).lastPathComponent,
                origin: withOrigin ? ResolveRepoOrigin.run(repo: record.repo) : nil,
                exists: exists,
                // 動いていた場所を手で消された場合。台帳には残っているので消失として見せる
                status: exists ? record.status : TaskStatus.missing,
                diff: exists ? diff(for: record) : DiffCounts(),
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt),
                now: now)
        }
    }

    /// 台帳から来る値だけを差し替える。**git を起動しない**。
    ///
    /// 状態や「いま触っているツール」はツールのたびに変わるので、差分を
    /// 数え直すまで出せないと後追いになる。差分と worktree の有無は前回の値を
    /// そのまま使い、数え直しは呼ぶ側の都合 (間隔・状態の変化) で回す。
    ///
    /// 顔ぶれ (ID) が変わっていたら前回の値を当てられないので nil を返す。
    /// 呼ぶ側はそのとき数え直す。
    ///
    /// 持ち主 (`origin`) は前回の値をそのまま持ち越すだけで、ここでは引かない。
    /// **`withOrigin: false` で集めた一覧を渡すと、持ち主は無いまま伝わり続ける。**
    public static func reapplied(_ tasks: [CollectedTask], records: [TaskRecord],
                                 now: Int = Int(Date().timeIntervalSince1970))
        -> [CollectedTask]? {
        // 顔ぶれの照合は、**どのみち要る辞書に相乗りさせる**。
        // ここは台帳が動くたび (= ツール1回ごと) に呼ばれるので、
        // 判定のためだけに Set を2つ作ると、そのぶんの確保が積み上がる
        guard tasks.count == records.count else { return nil }
        var previous: [String: CollectedTask] = [:]
        previous.reserveCapacity(tasks.count)
        for task in tasks { previous[task.id] = task }
        guard previous.count == records.count,
              records.allSatisfy({ previous[$0.id] != nil }) else { return nil }
        return ordered(records).compactMap { record in
            guard let old = previous[record.id] else { return nil }
            return CollectedTask(
                record: record,
                repoName: old.repoName,
                origin: old.origin,
                exists: old.exists,
                status: old.exists ? record.status : TaskStatus.missing,
                diff: old.diff,
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt),
                now: now)
        }
    }

    /// 新しい順。createdAt が同じものは台帳の並びを保つ
    /// (Swift の sorted は安定ではないので添字で決着をつける)
    static func ordered(_ records: [TaskRecord]) -> [TaskRecord] {
        records.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 作業量を数える。
    ///
    /// 見たいのは「そのエージェントが今やった分」なので HEAD からの差分、
    /// つまり未コミットの変更だけを数える。ベースブランチから数えると、
    /// もともと積まれていたコミットの歴史がまるごと出てしまい、
    /// 今の作業量が分からなくなる。
    ///
    /// 新規ファイルは git diff に出ないため untracked として別に数える。
    /// エージェントの成果はファイル追加であることが多く、ここが漏れると
    /// 「何もしていない」ように見えてしまう。
    ///
    /// バイナリも行では数えられないので、件数として別に持つ。
    /// 行数に混ぜると 0 になり、同じく「何もしていない」に見える。
    public static func diff(for record: TaskRecord) -> DiffCounts {
        // 聞けなかったときは 0 のまま出す。**ここは行に添える数字**で、
        // 消してよいかの判断には使わない (それは CollectWorktrees の仕事で、
        // あちらは「数え切れたか」を持ち回している)
        let lines = GitClient.changedLines(record.worktree, since: "HEAD")
        return DiffCounts(
            added: lines?.added ?? 0,
            removed: lines?.removed ?? 0,
            untracked: GitClient.untrackedCount(record.worktree) ?? 0,
            binary: lines?.binary ?? 0,
            changedFiles: lines?.files ?? 0)
    }

    /// まだ人が見ていないもの。**サイドバーの最上部に新着として出す分**。
    ///
    /// 集まるのは3つ。承認を待って止まっているもの (waiting)、終わったのに
    /// まだタブを見ていないもの (done)、落ちたのにまだ見ていないもの (failed)。
    ///
    /// **「未読」の線は台帳側 (MarkSessionSeen.needsMark) と揃える。** あちらが
    /// seenAt を打つ相手は done と failed なので、ここで別の線を引くと
    /// ✓ を押しても消えない行ができてしまう。
    ///
    /// done は seenAt が付くと attentionStatus が seen に畳まれるので、それで足りる。
    /// failed は見たあとも failed のまま出す (見たからといって片付いたわけではない)
    /// ので、こちらは seenAt を直に見る。
    ///
    /// 並びは TaskStatus.order の優先度が先、同じなら最後に動いた順。
    /// **同じ値のときは渡された順を保つ** (Swift の sorted は安定ではないので
    /// 添字で決着をつける。`ordered` や TaskGrouping と同じ考え方)
    public static func awaitingReview(_ tasks: [CollectedTask]) -> [CollectedTask] {
        tasks.filter(needsReview).enumerated().sorted { lhs, rhs in
            let (a, b) = (priority(lhs.element), priority(rhs.element))
            if a != b { return a < b }
            if lhs.element.idleSeconds != rhs.element.idleSeconds {
                return lhs.element.idleSeconds < rhs.element.idleSeconds
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// **線引きは持たない。** 同じ問い (まだ人の手が要るか) を macOS の通知側でも
    /// するので、答えは `TaskStatus.needsPerson` に1本だけ置いてある。
    /// ここに写しを作ると、片方だけ直したときに上と下で食い違う
    private static func needsReview(_ task: CollectedTask) -> Bool {
        TaskStatus.needsPerson(status: task.status, seenAt: task.seenAt)
    }

    /// 状態の並び順を優先度として使う。**ここに独自の順を作らない** —
    /// 一覧の内訳 (TaskStatus.counts) と違う順に並ぶと、上と下で緊急度が食い違う。
    ///
    /// 見るのは attentionStatus。displayStatus はタブを開いた時点で完了を
    /// seen に畳むので、それで並べると**開いた行だけが要確認の中で下がる**
    private static func priority(_ task: CollectedTask) -> Int {
        TaskStatus.order.firstIndex(of: task.attentionStatus) ?? TaskStatus.order.count
    }

    /// エージェントごとの最新レートリミット情報を集約する。
    ///
    /// タスク一覧と台帳のグローバルキャッシュの両方から最新値を集め、
    /// セッションが 0 件のときでも前回のレートリミットを常時表示できるようにする。
    /// ただし、リセット予定時刻 (resetsAt) を過ぎた枠は**出さない** — 明けたあとの
    /// 実際の使用率はエージェントが次に報告するまで分からないので、
    /// 0% と言い切るのも古い値を出し続けるのも嘘になる。両方の枠が過ぎていれば
    /// そのエージェントの行ごと消え、次の報告で戻る。
    public static func summarizedRateLimits(_ tasks: [CollectedTask],
                                           persisted: [String: AgentRateLimits] = LedgerStore.agentRateLimits(),
                                           now: Int = Int(Date().timeIntervalSince1970)) -> [AgentQuotaSummary] {
        var map: [String: AgentRateLimits] = persisted
        // persisted に無いエージェント（古い台帳からの移行など）のフォールバックとしてタスクから拾う。
        // tasks は新しい順 (createdAt 降順) に並んでいるため、最初に見つかった最新タスクのみを採用する。
        // 過去の完了タスクが最新の persisted や新しいタスクの rateLimits を上書きしないようにする。
        for task in tasks {
            guard let limits = task.rateLimits, !limits.isEmpty else { continue }
            let agentKey = task.resolvedAccountKey
            if map[agentKey] == nil {
                map[agentKey] = limits
            }
        }

        // リセット時刻を過ぎた枠は落とす
        var adjustedMap: [String: AgentRateLimits] = [:]
        for (agentKey, limits) in map {
            let adjusted = AgentRateLimits(fiveHour: live(limits.fiveHour, now: now),
                                           sevenDay: live(limits.sevenDay, now: now))
            if !adjusted.isEmpty {
                adjustedMap[agentKey] = adjusted
            }
        }

        func parseKey(_ key: String) -> (baseAgent: String, account: String?) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return (parts[0], parts[1])
            }
            return (key, nil)
        }

        // エージェントの決まった順 (AgentKind.order)、次にアカウント名順で安定させる
        return adjustedMap.keys.sorted { lhs, rhs in
            let (baseL, accL) = parseKey(lhs)
            let (baseR, accR) = parseKey(rhs)
            let p1 = AgentKind.order(baseL)
            let p2 = AgentKind.order(baseR)
            if p1 != p2 { return p1 < p2 }
            if baseL != baseR { return baseL < baseR }
            if (accL == nil) != (accR == nil) {
                return accL == nil
            }
            return (accL ?? "") < (accR ?? "")
        }.compactMap { key in
            guard let limits = adjustedMap[key] else { return nil }
            let (baseAgent, account) = parseKey(key)
            return AgentQuotaSummary(key: key, agent: baseAgent, account: account, rateLimits: limits)
        }
    }

    /// まだ有効な枠だけを返す。リセット時刻を過ぎたものは nil (= 出さない)。
    /// resetsAt が無いものは明ける時刻が分からないだけなので、そのまま残す。
    private static func live(_ window: RateLimitWindow?, now: Int) -> RateLimitWindow? {
        guard let window else { return nil }
        if let reset = window.resetsAt, reset <= now { return nil }
        return window
    }
}
