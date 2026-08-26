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
    public static func diff(for record: TaskRecord) -> DiffCounts {
        // 聞けなかったときは 0 のまま出す。**ここは行に添える数字**で、
        // 消してよいかの判断には使わない (それは CollectWorktrees の仕事で、
        // あちらは「数え切れたか」を持ち回している)
        let lines = GitClient.changedLines(record.worktree, since: "HEAD")
        return DiffCounts(
            added: lines?.added ?? 0,
            removed: lines?.removed ?? 0,
            untracked: GitClient.untrackedFiles(record.worktree)?.count ?? 0)
    }

    /// エージェントごとの最新レートリミット情報を集約する。
    ///
    /// タスク一覧と台帳のグローバルキャッシュの両方から最新値を集め、
    /// セッションが 0 件のときでも前回のレートリミットを常時表示できるようにする。
    /// また、リセット予定時刻（resetsAt）を過ぎている場合は使用率 0%（回復済み）として計算する。
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

        // リセット時刻が過ぎていたら自動で回復（0%）計算
        var adjustedMap: [String: AgentRateLimits] = [:]
        for (agentKey, limits) in map {
            var adjustedFive = limits.fiveHour
            if let five = adjustedFive, let reset = five.resetsAt, reset <= now {
                adjustedFive = RateLimitWindow(usedPercent: 0, resetsAt: nil)
            }
            var adjustedWeek = limits.sevenDay
            if let week = adjustedWeek, let reset = week.resetsAt, reset <= now {
                adjustedWeek = RateLimitWindow(usedPercent: 0, resetsAt: nil)
            }
            let adjusted = AgentRateLimits(fiveHour: adjustedFive, sevenDay: adjustedWeek)
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
}
