import Foundation

/// hooks から届く出来事を台帳に写す。
///
/// 台帳に載るのは、hooks が知らせてくれたセッションだけ。
/// proctor から worktree を作ることはないので、記録の入り口はここ1つになる。
public enum RecordHookEvent {
    /// 終了を取りこぼしたセッションの記録を捨てるまでの猶予
    public static let sessionTTL = 24 * 3600

    /// SubagentStop を取りこぼしたサブエージェントを捨てるまでの猶予。
    ///
    /// 親のターンの終わりでは掃除できない (子は親より長く生きる) ので、
    /// 時間で切るしかない。数えるのは**最後に声を聞いてから**なので、
    /// 動いている限り何時間走っていても消えない (`SubagentRun.lastSeen`)。
    ///
    /// 以前は 6時間だったが、中断 (Ctrl+C) やフックの取りこぼしが起きた際に
    /// 親タスクごと長時間「実行中」で居座ってしまうため、重いビルドや長考でも
    /// 誤判定されにくく、かつ実用的に回収できる 10分 (600秒) にしている。
    public static let subagentTTL = 10 * 60

    /// 「生きている」印を書き換える間隔。
    ///
    /// 子のイベントごとに書き換えると、中身の変わらないイベントでも台帳が動く。
    /// 台帳の更新時刻はサイドバーが変化を知る合図なので、そのたびに起こしてしまう。
    /// 打ち切りが時間単位である以上、分単位まで据え置いても困らない
    public static let subagentHeartbeat = 60

    /// 終わった子の墓標を持っておく時間。
    ///
    /// 弾きたいのは「SubagentStop の直後に遅れて届いた、その子のイベント」なので、
    /// 秒の単位で足りる。長く持ちすぎても台帳が太るだけ。
    ///
    /// **`agent_id` が使い回されない前提**に乗っている。同じ id を再利用する
    /// エージェントを繋ぐと、5分間その子が一覧に出なくなる
    public static let finishedSubagentTTL = 300

    /// Notification フックが何を意味するかを決める。
    ///
    /// このイベントは権限確認や質問のほかに、「60秒入力なし」のアイドル通知でも
    /// 発火する。アイドルまで確認待ちにすると、終わったあと放置しただけで
    /// 印が付いてしまう。待たせているのはこちらではないので状態を変えない。
    ///
    /// - Returns: 記録すべき状態。何もしないときは nil。
    public static func resolveNotification(_ payload: HookPayload) -> String? {
        payload.message.contains("waiting for your input") ? nil : TaskStatus.waiting
    }

    /// 状態を書き込む。知らないセッションなら新しく登録する。
    ///
    /// - Returns: **実際に記録した状態**。呼び出し側 (タブの色を変える hooks など) が
    ///   台帳と食い違わないように、届いた状態そのままとは限らない値を返す。
    ///   記録しなかったとき (git の外など) は届いた状態をそのまま返す
    @discardableResult
    public static func touch(status: String, payload raw: HookPayload) throws -> String {
        let top = GitClient.toplevel(from: raw.workingDirectory)
        guard !top.isEmpty else { return status }  // git の外での実行は追いかけない

        let now = Int(Date().timeIntervalSince1970)

        // 読むだけで済む仕事はここで全部片付ける (理由は LedgerStore.withLock)。
        //
        // 支度が要るかどうかを台帳を覗いて決めているが、**見立てを外しても害は無い。**
        // 用意したものを使うかはロックの中で改めて確かめるので、二重には登録されない
        let snapshot = LedgerStore.read()
        let payload = raw.resolvingAntigravitySubagent(in: snapshot)
        let facts = SessionFacts(payload)
        let draft = findTask(in: snapshot, payload: payload) == nil
            ? draftRegistration(status: status, payload: payload, facts: facts,
                                top: top, now: now)
            : nil

        return try LedgerStore.withLock { ledger in
            // このフックを送ってきたセッションだけは掃除から外す。生きている証拠が
            // いま届いているのに消すのはおかしいし、--resume で開き直したときに
            // 「前のプロセスが死んでいる」を理由に落とすと、付けた名前も経過時間も
            // 引き継げず、別のタスクとして並び直してしまう
            let current = findTask(in: ledger, payload: payload).map { ledger.tasks[$0].id }
            sweepLedger(&ledger, now: now, keeping: current)

            // 親に付いた子が、以前は独立した行として登録されていたなら引き取る。
            //
            // 子の最初のイベントの時点では親子を結べないことがある (生成の記録が
            // まだ親のログに書かれていない)。そのとき子は自分の名前で登録され、
            // あとから結ばれると**誰もその行を見に来なくなる**。
            // Antigravity は pid を出さないので期限切れの掃除にも掛からず、
            // 「実行中」のまま永久に居座ってしまう
            if let subID = payload.subagentID, payload.sessionID != subID {
                ledger.tasks.removeAll { $0.sessionId == subID }
            }

            guard let index = findTask(in: ledger, payload: payload) else {
                // 支度が無いのは、ロックを取る前には居たのに今は居ない場合
                // (入れ違いで `clear` が来た・アプリが片付けた)。
                // その回は捨てる。次のフックで登録し直される
                try enroll(&ledger, draft: draft, top: top, agentKey: payload.agentKey)
                return status
            }

            if status == "clear" {
                if let subID = payload.subagentID {
                    removeSubagent(&ledger.tasks[index], id: subID, now: now)
                    settleHold(&ledger.tasks[index], now: now)
                    return status
                }
                // セッションが終わったら一覧から消す
                ledger.tasks.remove(at: index)
                return status
            }

            // 子から届いた出来事 (PostToolUse / Stop 等) の場合。
            // 親自身の状態やタイトルを書き換えてはいけないので、子の手元だけを更新する
            if let subID = payload.subagentID {
                if status == TaskStatus.done || status == TaskStatus.failed {
                    removeSubagent(&ledger.tasks[index], id: subID, now: now)
                    settleHold(&ledger.tasks[index], now: now)
                } else {
                    applySubagents(&ledger.tasks[index], payload: payload, now: now)
                }
                return ledger.tasks[index].status
            }

            // **子がまだ走っているなら「終わった」とは書かない。**
            //
            // サブエージェントは非同期に起動されるので、親のターンは子を待たずに
            // 終わり、その時点で Stop が飛んでくる (子が終わると task-notification で
            // 親が起こされ、また動き出す)。これをそのまま完了にすると、
            // まだ誰も待たせていないセッションに緑の印が付き、しばらくして
            // 実行中に戻る。「色が付いている = まだ手を付けていない」が壊れる
            let hasLiveSubagents = !(ledger.tasks[index].subagentRuns ?? []).isEmpty
            let recorded: String
            if (status == TaskStatus.done || status == TaskStatus.failed), hasLiveSubagents {
                recorded = TaskStatus.running
                // 捨てずに預ける。最後の子が帰ってきたときに、これを見て終わらせる
                ledger.tasks[index].pendingStatus = status
            } else {
                recorded = status
                // 預かった終わりを捨てていいのは、**改めて Stop が来ることが
                // 保証される合図**のときだけ。それが新しいターンの始まりで、
                // 子に起こされた場合もここを通る (task-notification が prompt に載る)。
                //
                // 確認待ち (waiting) では捨てない。親が仕事を再開した証にならないので、
                // 捨てると最後の子が帰ってきたときに終わらせる者がいなくなり、
                // 確認待ちのまま居座る
                if payload.isTurnStart {
                    ledger.tasks[index].pendingStatus = nil
                }
            }

            // 変わったところだけ触る。何も変わらなければ LedgerStore.withLock が
            // 書き込みごと省くので、台帳の更新時刻が動かずサイドバーも数え直さない。
            // PostToolUse のように何度も飛んでくるイベントを受けられるのはこのため
            if ledger.tasks[index].status != recorded {
                ledger.tasks[index].status = recorded
                ledger.tasks[index].updatedAt = now
                // また動き出したら「確認した」は無かったことにする。
                // 次に終わったときは別の結果なので、改めて見てほしい
                if recorded == TaskStatus.running || recorded == TaskStatus.waiting {
                    ledger.tasks[index].seenAt = nil
                }
            }
            if let session = payload.sessionID, ledger.tasks[index].sessionId != session {
                ledger.tasks[index].sessionId = session
            }
            if let iterm = EnvironmentSource.itermSessionID(),
               ledger.tasks[index].itermSession != iterm {
                ledger.tasks[index].itermSession = iterm
            }
            // --resume で開き直すと同じセッションでもプロセスが変わるので、
            // 毎回入れ直す。同じプロセスなら起動時刻も動かないため書き込みは増えない
            if let pid = EnvironmentSource.agentPID() {
                let startedAt = ProcessLiveness.startedAt(pid: pid)
                if ledger.tasks[index].pid != pid
                    || ledger.tasks[index].pidStartedAt != startedAt {
                    ledger.tasks[index].pid = pid
                    ledger.tasks[index].pidStartedAt = startedAt
                }
            }
            if let agent = payload.agent, ledger.tasks[index].agent != agent {
                ledger.tasks[index].agent = agent
            }
            if let name = facts.name, ledger.tasks[index].name != name {
                ledger.tasks[index].name = name
            }
            // 人が付けた名前。空文字で渡されたら外す (キーが無いときは触らない)
            if let tabTitle = facts.tabTitle {
                let trimmed = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? nil : trimmed
                if ledger.tasks[index].title != value {
                    ledger.tasks[index].title = value
                }
            }
            if let model = facts.model, ledger.tasks[index].model != model {
                ledger.tasks[index].model = model
            }
            if let ctx = facts.contextPercent, ledger.tasks[index].contextPercent != ctx {
                ledger.tasks[index].contextPercent = ctx
            }
            // レートリミットは普通 statusline (`_stats`) が運んでくる。
            // **Codex には statusline に相当する差し込み口が無い**ので、
            // そちらだけは hooks の経路でも受け取る。他のエージェントの payload には
            // 入っていないので、ここは素通りするだけで何も変わらない
            if let limits = facts.rateLimits {
                if ledger.tasks[index].rateLimits != limits {
                    ledger.tasks[index].rateLimits = limits
                }
                let key = payload.agentKey
                if ledger.agentRateLimits[key] != limits {
                    ledger.agentRateLimits[key] = limits
                }
            }
            // いま何をしているか。updatedAt はここでは動かさない
            // (ツールのたびに動かすと「経過」が 0 に戻り、並び順も落ち着かない)。
            //
            // ここに渡すのは書き込む状態 (recorded) ではなく**届いた状態**。
            // 子を待っている親は実行中のままにするが、親自身はもう何も
            // 触っていないので、ツールの行は消したい
            switch resolveActivity(status: status, payload: payload) {
            case .keep:
                break
            case .clear:
                ledger.tasks[index].activity = nil
            case .set(let text):
                ledger.tasks[index].activity = text
            }
            // サブエージェントの素性と手元。親の行とは別に持つ
            applySubagents(&ledger.tasks[index], payload: payload, now: now)

            if (status == TaskStatus.done || status == TaskStatus.failed),
               !hasLiveSubagents, (ledger.tasks[index].subagents ?? 0) != 0 {
                // 数だけを持つエージェント (agent_id を送ってこないもの) の取りこぼしを戻す。
                // あちらは SubagentStop を落とすと数がずれたままになるので、
                // ターンの終わりを唯一の掃除どころにしている。
                //
                // **1体ずつ持てるほうはここで消さない。** 子は親のターンより
                // 長く生きるので、ここで消すと走っている最中の子が一覧から消え、
                // 次のツールでラベルを失った状態で生え直す。
                // あちらの掃除は SubagentStop (と subagentTTL) が引き受ける
                ledger.tasks[index].subagents = 0
            }
            return recorded
        }
    }

    /// サブエージェントの出入りを記録する。
    ///
    /// `agent_id` が付いているなら1体ずつ持つ (SubagentStart / SubagentStop)。
    /// 付いていないエージェントは今まで通り数だけを増減させる
    /// (PreToolUse(Task) で増やし、SubagentStop で減らす)。
    /// どちらの経路も、取りこぼしはターンの終わり (touch done) で戻る。
    public static func countSubagent(delta: Int, payload raw: HookPayload) throws {
        // 親子の解決は親のログを読むので、ロックを取る前に済ませる
        let payload = raw.resolvingAntigravitySubagent(in: LedgerStore.read())
        try LedgerStore.withLock { ledger in
            guard let index = findTask(in: ledger, payload: payload) else { return }
            let now = Int(Date().timeIntervalSince1970)
            pruneSubagents(&ledger.tasks[index], now: now)

            guard let id = payload.subagentID else {
                // 数だけを持つエージェント。ここは今までどおり updatedAt を動かす
                ledger.tasks[index].subagents =
                    max(0, (ledger.tasks[index].subagents ?? 0) + delta)
                ledger.tasks[index].updatedAt = now
                return
            }

            // 1体ずつ持てる経路では **updatedAt を動かさない。** 子が出入りする
            // たびに動かすと「経過」がその都度 0 に戻り、長く走っているセッションを
            // 見失う (いま触っているツールを載せるときと同じ理由)。
            // 状態が本当に変わるとき (預かった終わりの確定) だけは動かす
            if delta > 0 {
                upsertSubagent(&ledger.tasks[index], id: id, now: now) { run in
                    if let type = payload.subagentType { run.type = type }
                }
            } else {
                removeSubagent(&ledger.tasks[index], id: id, now: now)
                // 古い繋ぎ方 (PreToolUse でも +1 する) が残ったままでも
                // 数が居座らないよう、こちらも一緒に戻す
                if let count = ledger.tasks[index].subagents, count > 0 {
                    ledger.tasks[index].subagents = count - 1
                }
                // 最後の1体が帰ってきた。親が先に終わりを告げていたなら、
                // ここで確定させる。そうしないと、終わったセッションが
                // 実行中のまま一覧に居座る (Stop はもう二度と来ない)
                settleHold(&ledger.tasks[index], now: now)
            }
        }
    }

    // MARK: - サブエージェント

    /// 届いた payload からサブエージェントの素性と手元を写す。
    ///
    /// 拾えるものが2つある。
    ///
    /// - **起動の記録** (Task/Agent ツールの PostToolUse)。`tool_response` に
    ///   `agentId` と description が揃って入っている唯一の場所で、ここで
    ///   「どの子に何をさせたか」が結べる
    /// - **子の手元** (子の中で発火した PostToolUse)。`agent_id` が付いてくるので、
    ///   親の activity ではなくその子の行に書く
    ///
    /// どちらも upsert にしてあるのは、SubagentStart を繋いでいなくても
    /// 一覧が出るようにするため。順番が入れ替わっても取りこぼさない。
    static func applySubagents(_ task: inout TaskRecord, payload: HookPayload, now: Int) {
        if let launched = payload.launchedSubagent {
            upsertSubagent(&task, id: launched.id, now: now) { run in
                if let type = launched.type { run.type = type }
                if let label = launched.label { run.label = label }
            }
        }
        if let id = payload.subagentID {
            upsertSubagent(&task, id: id, now: now) { run in
                if let type = payload.subagentType { run.type = type }
                if let activity = payload.toolActivity { run.activity = activity }
            }
        }
    }

    static func upsertSubagent(_ task: inout TaskRecord, id: String, now: Int,
                               _ edit: (inout SubagentRun) -> Void) {
        var runs = task.subagentRuns ?? []
        if let index = runs.firstIndex(where: { $0.id == id }) {
            edit(&runs[index])
            // まだ生きている印。打ち切りはここから数える。
            // 毎回書き換えると無変更のイベントでも台帳が動くので、間隔を空ける
            if now - runs[index].lastSeen >= subagentHeartbeat {
                runs[index].lastSeenAt = now
            }
        } else {
            // もう終わった子なら生やさない。hooks は非同期に飛ぶので、
            // SubagentStop のあとにその子の PostToolUse が遅れて届く。
            // ここで受けると、二度と終わりを告げられない行が生まれてしまう
            guard task.finishedSubagents?[id] == nil else { return }
            var run = SubagentRun(id: id, startedAt: now)
            edit(&run)
            runs.append(run)
        }
        task.subagentRuns = runs
    }

    /// 1体消す。空になったらキーごと落とす (無い項目は書き出さない台帳の流儀に合わせる)。
    /// 消した相手は墓標に残す (遅れて届くその子のイベントを弾くため)
    static func removeSubagent(_ task: inout TaskRecord, id: String, now: Int) {
        var runs = task.subagentRuns ?? []
        runs.removeAll { $0.id == id }
        task.subagentRuns = runs.isEmpty ? nil : runs

        var finished = task.finishedSubagents ?? [:]
        finished[id] = now
        task.finishedSubagents = finished
    }

    /// 声を聞かなくなった子と、古い墓標を捨てる。
    ///
    /// 子のほうは、終わりを取りこぼしたときの受け皿。親のターンの終わりでは
    /// 掃除できない (子は親より長く生きる) ので、時間で切るしかない。
    /// **数えるのは生まれてからではなく、最後に声を聞いてから。**
    /// 生まれた時刻で切ると、長く走っている子を動いている最中に消してしまい、
    /// その拍子に親の預かった終わりが確定して完了の印が付く。
    static func pruneSubagents(_ task: inout TaskRecord, now: Int) {
        if var runs = task.subagentRuns {
            runs.removeAll { now - $0.lastSeen >= subagentTTL }
            task.subagentRuns = runs.isEmpty ? nil : runs
        }
        if var finished = task.finishedSubagents {
            finished = finished.filter { now - $0.value < finishedSubagentTTL }
            task.finishedSubagents = finished.isEmpty ? nil : finished
        }
    }

    /// 預かった終わりを確定させる。子が誰も居なくなっていれば。
    ///
    /// **いまの状態は見ない。確認待ちでも上書きする。** 預かりを持つのは
    /// 「親がもう Stop を告げている」ということなので、そのあとの確認待ちは
    /// 子が上げたもの。その子が帰ってきた時点で、待たせている相手はもういない。
    /// ここを「実行中のときだけ」に絞ると、確認待ちのまま居座る経路ができる
    static func settleHold(_ task: inout TaskRecord, now: Int) {
        guard task.subagentRuns == nil, let held = task.pendingStatus else { return }
        task.status = held
        task.pendingStatus = nil
        task.updatedAt = now
    }

    // MARK: -

    /// 「いま触っているツール」をどうするか。
    ///
    /// 何も返せない (`keep`) と消す (`clear`) は別物にしておく。フックの多くは
    /// ツールの情報を持たずに飛んでくるので、区別しないと1つのイベントごとに
    /// 消えて出てを繰り返す。
    enum ActivityUpdate: Equatable {
        case keep
        case clear
        case set(String)
    }

    /// - ターンが終わった (done / failed) → 何もしていないので消す
    /// - ターンが始まった (UserPromptSubmit) → 前のターンの残りを消す
    /// - 子が叩いたツール (agent_id 付き) → 触らない。それは子の行に出す
    /// - 子を起動したツール → 触らない。何をさせたかは子の行が語る
    /// - ツールを叩いた (PostToolUse) → それを載せる
    /// - それ以外 → 触らない。確認待ちの間も、直前に何をしていたかは残したい
    static func resolveActivity(status: String, payload: HookPayload) -> ActivityUpdate {
        if status == TaskStatus.done || status == TaskStatus.failed { return .clear }
        if payload.isTurnStart { return .clear }
        // 子のツールは親と同じ session_id で飛んでくる。区別せずに載せると、
        // 親の行が子の作業で塗り替わって「親がいま何をしているか」が分からなくなる
        if payload.subagentID != nil { return .keep }
        if payload.launchedSubagent != nil { return .keep }
        if let activity = payload.toolActivity { return .set(activity) }
        return .keep
    }

    /// payload から取り出すのに**外の世界を触る**値をまとめて持つ。
    ///
    /// どれも見た目はただのプロパティだが、名前も文脈量もエージェントの手元の
    /// 記録を読みに行く (SQLite やログの走査)。**写しにしておくのは、
    /// ロックの中でうっかり読ませないため。** 登録と更新の両方で同じ値が要るので、
    /// 素直に書くとどちらかがロックの内側に残る
    struct SessionFacts {
        var name: String?
        var tabTitle: String?
        var model: String?
        var contextPercent: Int?
        var rateLimits: AgentRateLimits?

        init(_ payload: HookPayload) {
            name = payload.sessionName
            tabTitle = payload.tabTitle
            model = payload.modelName
            contextPercent = payload.contextPercent
            rateLimits = payload.rateLimits
        }
    }

    /// 新しく登録する1件を組み立てる。**ロックの外で呼ぶこと** (git を2回起こす)。
    ///
    /// 新しく登録するのは、これから動き出すときだけにする。
    /// done や clear が単独で届くのは、終了処理が入れ違いになったときで
    /// (clear は同期・done は非同期なので追い越しうる)、ここで作ると
    /// 終わったはずのセッションが幽霊として一覧に戻ってしまう。
    ///
    /// セッションIDが取れないものも登録しない。次に来たときに照合できず、
    /// 呼ばれるたびに新しいタスクが積み上がる。
    ///
    /// - Returns: 登録すべきものが無ければ nil。
    ///   **ID はまだ空。** 他と重ならない名前は台帳を見ないと決められないので、
    ///   採番は `enroll` がロックの中で行う
    private static func draftRegistration(status: String, payload: HookPayload,
                                          facts: SessionFacts,
                                          top: String, now: Int) -> TaskRecord? {
        guard status == TaskStatus.running || status == TaskStatus.waiting,
              let session = payload.sessionID else { return nil }

        let branch = GitClient.currentBranch(top)
        let pid = EnvironmentSource.agentPID()
        return TaskRecord(
            id: "",
            repo: GitClient.mainWorktree(from: top) ?? top,
            branch: branch.isEmpty ? "-" : branch,
            worktree: top,
            sessionId: session,
            itermSession: EnvironmentSource.itermSessionID(),
            pid: pid,
            pidStartedAt: pid.flatMap { ProcessLiveness.startedAt(pid: $0) },
            status: status,
            createdAt: now,
            updatedAt: now,
            agent: payload.agent,
            // 最初の1件目が PostToolUse のこともある (前のセッションの記録を
            // 消したあとなど)。そのときも何をしているかは載せておく。
            // ただし子が叩いたツールは親の手元ではないので載せない
            activity: payload.subagentID == nil ? payload.toolActivity : nil,
            title: facts.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            name: facts.name,
            model: facts.model,
            contextPercent: facts.contextPercent,
            // statusline を持たないエージェント (Codex) はここでしか渡す機会がない。
            // 持っているほうは payload に入っていないので nil のまま通る
            rateLimits: facts.rateLimits)
    }

    /// 組み立てておいた1件を台帳に載せる。**ここだけがロックの中。**
    ///
    /// やるのは採番と追加だけ。外から材料を持ち込む形にしてあるのは、
    /// ロックを握っている時間を数ミリ秒に抑えるため。
    private static func enroll(_ ledger: inout LedgerFile, draft: TaskRecord?,
                               top: String, agentKey: String) throws {
        guard var record = draft else { return }
        record.id = try TaskID.unique(
            base: TaskID.slugify(URL(fileURLWithPath: top).lastPathComponent),
            taken: ledger.tasks)
        ledger.tasks.append(record)
        if let limits = record.rateLimits {
            ledger.agentRateLimits[agentKey] = limits
        }
    }

    /// hook の情報から対象のタスクを引く。
    ///
    /// PROCTOR_ID → セッションID の順に照合する。
    /// 場所では照合しない。セッションは同じリポジトリで何枚も開くものなので、
    /// パスでまとめると2枚目以降が1枚目の記録を上書きして消えてしまう。
    static func findTask(in ledger: LedgerFile, payload: HookPayload) -> Int? {
        if let envID = EnvironmentSource.taskID(),
           let index = ledger.tasks.firstIndex(where: { $0.id == envID }) {
            return index
        }
        guard let session = payload.sessionID else { return nil }
        return ledger.tasks.firstIndex { $0.sessionId == session }
    }

    /// 台帳ぜんぶに箒をかける。イベントが届くたび、書き込む前に1回。
    ///
    /// やることは3つ。**どれも「当人からはもうイベントが来ない」記録が相手**なので、
    /// 全件を見るこの場所でしか手が届かない。
    ///
    /// 1. 終了を取りこぼしたセッションの記録を捨てる
    /// 2. 声を聞かなくなった子と古い墓標を捨てる
    /// 3. 子が居なくなった親の、預かった終わりを確定させる
    ///
    /// 1は SessionEnd が飛ばないまま終わることがあるため (タブごと閉じられた・
    /// 殺された)。判断は2段構えになっている。
    ///
    /// - **プロセスが分かるもの**: 生きているかどうかで決める。死んでいれば状態に
    ///   関係なく落とす。実行中のまま殺されたセッションは、これが無いと
    ///   期限切れ (下) にも引っかからず永久に残ってしまう
    /// - **プロセスが分からないもの** (Claude Code 以外・この変更より前の記録):
    ///   生死を確かめる手立てが無いので期限切れに任せる。
    ///   ただし実行中のものは残す。更新時刻は状態が変わったときだけ動くので、
    ///   長いターンを回している間は時刻が古いままになる。まさに追いかけたい
    ///   「夜通し動いているエージェント」を消してしまっては本末転倒になる
    ///
    /// - Parameter keeping: 何があっても残すタスクのID。いま知らせてきた当人を指す。
    /// - Parameter isAlive: プロセスの生死。差し替えられるようにしてあるのは試験のため。
    static func sweepLedger(
        _ ledger: inout LedgerFile, now: Int, keeping: String? = nil,
        isAlive: (Int, Int?) -> Bool = { ProcessLiveness.isAlive(pid: $0, startedAt: $1) }
    ) {
        ledger.tasks.removeAll { task in
            if let keeping, task.id == keeping { return false }
            if let pid = task.pid { return !isAlive(pid, task.pidStartedAt) }
            return task.status != TaskStatus.running && now - task.updatedAt >= sessionTTL
        }
        for index in ledger.tasks.indices {
            pruneSubagents(&ledger.tasks[index], now: now)
            settleHold(&ledger.tasks[index], now: now)
        }
    }
}
