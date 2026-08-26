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

    /// リポジトリを「最近見た」と書き直す間隔。
    ///
    /// hook のたびに時刻を入れ直すと、そのたびにサイドバーが起きて数え直す
    /// (理由は subagentHeartbeat と同じ)。この時刻は覚えているリポジトリが
    /// 上限を超えたときに古い順で落とすためだけの値なので、日単位でも困らない
    public static let repoMemoryRefresh = 24 * 3600

    /// 覚えておくリポジトリの数の上限。
    ///
    /// 使わなくなったリポジトリのパスが際限なく溜まらないようにするための蓋。
    /// 溢れたら「最後に見た」が古いものから落とす
    public static let repoMemoryLimit = 50

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
    /// このイベントは権限確認や質問のほかに、「応答が終わって60秒、その間
    /// 何も打っていない」のアイドル通知でも発火する。アイドルまで確認待ちに
    /// すると、終わったあと放置しただけで印が付いてしまう。
    ///
    /// アイドル通知は捨てずに `settled` として受ける。**あれが届いたということは
    /// 応答が終わっているということ**なので、確認待ちで居座っている行を降ろせる
    /// (権限確認をキャンセルするとフックが1つも飛ばない。理由は TaskStatus.settled)。
    ///
    /// **見分けるのは種別 (`notification_type`) で、文言では見ない。**
    /// 文言は版で変わるし、公式に決まっているのは種別のほう。
    /// 種別を送ってこない古い版のためだけに、文言の当て推量を残してある。
    ///
    /// - Returns: 記録すべき状態か指示。**何もしないときは nil**。
    ///
    /// このイベントは人に用がある通知だけではない。認証できた・ダイアログが
    /// 閉じた・利用制限から自動再開した、も同じ口から届く。**全部を確認待ちに
    /// 寄せると、認証しただけで印が付き、その後フックが来なければ居座る。**
    public static func resolveNotification(_ payload: HookPayload) -> String? {
        guard let type = payload.notificationType else {
            // 種別を送ってこない古い版。文言しか手がかりが無い。
            // 当たらなければ確認待ちに寄せる (下の default と同じ理由)
            return payload.message.contains("waiting for your input")
                ? TaskStatus.settled : TaskStatus.waiting
        }
        switch type {
        // 人に用がある。手を挙げているのはこれら
        case "permission_prompt",          // ツールの権限確認
             "elicitation_dialog",         // MCP サーバーが入力を求めた
             "elicitation_url_dialog",     // MCP サーバーがブラウザを開くよう求めた
             "agent_needs_input",          // 裏で走っているセッションが入力待ちになった
             "quota_auto_resume_stale":    // 制限が明けて Enter 待ちになった
            return TaskStatus.waiting
        // 待たせていたものが終わった。確認待ちで居座っている行を降ろす
        case "idle_prompt",                // 応答が終わって60秒、その間入力なし
             "elicitation_complete",       // 入力フォームが送られた・破棄された
             "elicitation_response":       // その応答がサーバーへ返った
            return TaskStatus.settled
        // 状態の話ではない。触らない
        case "auth_success", "agent_completed",
             "quota_auto_resume_fired", "quota_auto_resume_disabled":
            return nil
        default:
            // 知らない種別。**見落とすより、余分に印が付くほうを取る。**
            // 種別は版ごとに増えるので、ここに落ちるのは新しい版で使う人
            return TaskStatus.waiting
        }
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
        let known = findTask(in: snapshot, payload: payload)
        let draft = known == nil
            ? draftRegistration(status: status, payload: payload, facts: facts,
                                top: top, now: now)
            : nil
        // リポジトリ本体の場所。**ここで git を起こし直さない。**
        // 既に居るセッションなら台帳が答えを持っているし、初めてなら支度 (draft) を
        // 組み立てたときに引いている。hooks は際限なく飛んでくるので、
        // 分かっている答えのために毎回プロセスを起こすわけにいかない
        let repo = known.map { snapshot.tasks[$0].repo } ?? draft?.repo

        return try LedgerStore.withLock { ledger in
            if let repo { rememberRepo(&ledger, path: repo, now: now) }
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

            // 「もう待っていない」の合図。**確認待ちを降ろすためだけに使う。**
            //
            // 何をしていたかは分からないので、完了にはしない (キャンセルされた
            // ターンに ✅ を付けると、見るべき結果があることになってしまう)。
            // 動いている最中や終わったあとに届いた分は何もしない —— あれは
            // ただの「暇になった」で、状態の話ではない
            if status == TaskStatus.settled {
                // **子の手元で起きた通知で親を降ろさない。** 親自身のプロンプトが
                // 開いている最中に子が暇になっただけ、という組み合わせがある
                guard payload.subagentID == nil,
                      ledger.tasks[index].status == TaskStatus.waiting else {
                    return ledger.tasks[index].status
                }
                // 降ろし方は人が押したときと同じところを通す (理由はそちら)
                return ClearAttention.standDown(&ledger.tasks[index])
            }

            // **既に居るセッションを idle で塗り替えない。**
            //
            // SessionStart は再開のときだけでなく、会話の圧縮 (compact) や
            // clear でも飛ぶ。素直に受けると、動いている最中のセッションが
            // その拍子に「待機中」へ落ちる。idle が意味を持つのは
            // 「まだ台帳に居ないセッションが始まった」ときだけ。
            // ただし「誰がどこで動いているか」は入れ直す (理由は rebind)
            if status == TaskStatus.idle {
                rebind(&ledger.tasks[index], payload: payload)
                // **承認待ちの文だけは持ち越さない。** SessionStart が届いたのは
                // セッションが開き直された (あるいは圧縮・clear された) ときなので、
                // 前に出ていた権限確認はもう画面に無い。状態を塗り替えない方針は
                // そのままなので、確認待ちのまま残ることはある (それは別の話)
                ledger.tasks[index].request = nil
                return ledger.tasks[index].status
            }

            // 子から届いた出来事 (PostToolUse / Stop 等) の場合。
            // 親自身の状態やタイトルを書き換えてはいけないので、子の手元だけを更新する
            if let subID = payload.subagentID {
                if status == TaskStatus.done || status == TaskStatus.failed {
                    removeSubagent(&ledger.tasks[index], id: subID, now: now)
                    settleHold(&ledger.tasks[index], now: now)
                } else {
                    applySubagents(&ledger.tasks[index], payload: payload,
                                   status: status, now: now)
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
            rebind(&ledger.tasks[index], payload: payload)
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
            // 何の承認を待っているか。**渡すのも届いた状態**で、理由は上と同じ
            switch resolveRequest(status: status, payload: payload) {
            case .keep:
                break
            case .clear:
                if ledger.tasks[index].request != nil {
                    ledger.tasks[index].request = nil
                }
            case .set(let text):
                if ledger.tasks[index].request != text {
                    ledger.tasks[index].request = text
                }
            case .fallback(let text):
                if ledger.tasks[index].request == nil {
                    ledger.tasks[index].request = text
                }
            }
            // サブエージェントの素性と手元。親の行とは別に持つ
            applySubagents(&ledger.tasks[index], payload: payload, status: status, now: now)

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
                // 最後の1体が帰ったなら、預かった終わりを確定させる。
                // **1体ずつ持てる経路と揃える** (下の removeSubagent のあとと同じ)。
                // ここが無いと、この経路のセッションだけ預かったものが宙に浮く
                if ledger.tasks[index].subagents == 0 {
                    settleHold(&ledger.tasks[index], now: now)
                }
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
    /// - Parameter status: 届いた状態。**子の手元にも門番が要る。**
    ///   確認待ちで届くツールは権限確認に出ているだけで、まだ実行されていない
    ///   (親の行に載せない理由と同じ。`resolveActivity` を参照)
    static func applySubagents(_ task: inout TaskRecord, payload: HookPayload,
                               status: String, now: Int) {
        if let launched = payload.launchedSubagent {
            upsertSubagent(&task, id: launched.id, now: now) { run in
                if let type = launched.type { run.type = type }
                if let label = launched.label { run.label = label }
            }
        }
        if let id = payload.subagentID {
            upsertSubagent(&task, id: id, now: now) { run in
                if let type = payload.subagentType { run.type = type }
                if status != TaskStatus.waiting, let activity = payload.toolActivity {
                    run.activity = activity
                }
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
        // 確認待ちが解けたのだから、承認待ちの文も一緒に落とす。
        // **表示は状態で隠せるが、台帳に残すと次の確認を弾いてしまう**
        // (弱い方の書き込みは request が空のときだけ入るため)
        task.request = nil
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
        // 確認待ちで届くツールは**まだ実行されていない**もの (権限確認)。
        // ここに載せると、承認していないコマンドを「いま触っているもの」として
        // 出してしまう。断られたときは実行されないまま残る。載せる先は request
        if status == TaskStatus.waiting { return .keep }
        // 子のツールは親と同じ session_id で飛んでくる。区別せずに載せると、
        // 親の行が子の作業で塗り替わって「親がいま何をしているか」が分からなくなる
        if payload.subagentID != nil { return .keep }
        if payload.launchedSubagent != nil { return .keep }
        if let activity = payload.toolActivity { return .set(activity) }
        return .keep
    }

    /// 「何の承認を待っているか」をどうするか。
    ///
    /// - 確認待ちになった → 何を訊かれているかを載せる
    /// - それ以外の状態になった → 消す。**承認された瞬間に消えることがここの要**で、
    ///   残すと動き出したセッションに「承認待ち」の文が付いて回る
    /// - 子が上げた確認 (agent_id 付き) → 触らない。親の行に子の話を混ぜない
    ///
    /// 載せるものは2段構え。ツールの情報が来ていれば `toolActivity` と同じ
    /// 組み立て ("Bash: mkdir -p /tmp/x") を使い、無ければ通知の文を置く。
    /// **後者はツール名までしか言わない** ("Claude needs your permission to
    /// use Bash") ので、コマンドまで出したいなら権限確認そのもののフックを繋ぐ
    /// (手引きに書いてある)。
    enum RequestUpdate: Equatable {
        case keep
        case clear
        /// ツールから組んだもの。**上書きしてよい**
        case set(String)
        /// 通知の文から拾ったもの。**すでに何か載っているなら譲る。**
        ///
        /// 権限確認では権限確認のフックと `Notification` の両方が飛び、着く順は
        /// 決まっていない。譲らせないと、コマンドまで分かっていた行が
        /// 「ツール名しか言わない文」で塗り潰される (順番次第で消える)
        case fallback(String)
    }

    static func resolveRequest(status: String, payload: HookPayload) -> RequestUpdate {
        guard status == TaskStatus.waiting else { return .clear }
        if payload.subagentID != nil { return .keep }
        if let tool = payload.toolActivity { return .set(tool) }
        let message = payload.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return .keep }
        return .fallback(HookPayload.condensed(message))
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

    /// 登録するときに載せる値。`keep` と `clear` はどちらも「まだ無い」に落ちる
    private static func firstText(_ update: ActivityUpdate) -> String? {
        if case .set(let text) = update { return text }
        return nil
    }

    private static func firstText(_ update: RequestUpdate) -> String? {
        switch update {
        case .set(let text), .fallback(let text): return text
        case .keep, .clear: return nil
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
        guard status == TaskStatus.running || status == TaskStatus.waiting
                || status == TaskStatus.idle,
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
            // 最初の1件目が PostToolUse や権限確認のこともある (前のセッションの
            // 記録を消したあとなど)。そのときも何をしているか・何を待っているかを
            // 載せておく。**判断は更新のときと同じところを通す** —
            // ここに書き分けを作ると、登録した回だけ違うものが載る
            // (子が叩いたツールを載せない門番も、そちらが持っている)
            activity: firstText(resolveActivity(status: status, payload: payload)),
            request: firstText(resolveRequest(status: status, payload: payload)),
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

    /// 記録を**いま動いているプロセスとタブに結び直す**。状態には触らない。
    ///
    /// `--resume` は同じセッションIDのまま別のプロセス・別のタブで開き直すので、
    /// ここを入れ直さないと、死んだプロセスの記録として掃除されてしまう。
    /// 変わらなければ何も書かないので、台帳の更新時刻は動かない。
    static func rebind(_ record: inout TaskRecord, payload: HookPayload) {
        if let session = payload.sessionID, record.sessionId != session {
            record.sessionId = session
        }
        if let iterm = EnvironmentSource.itermSessionID(), record.itermSession != iterm {
            record.itermSession = iterm
        }
        if let pid = EnvironmentSource.agentPID() {
            let startedAt = ProcessLiveness.startedAt(pid: pid)
            if record.pid != pid || record.pidStartedAt != startedAt {
                record.pid = pid
                record.pidStartedAt = startedAt
            }
        }
    }

    /// セッションを見たリポジトリを覚えておく。
    ///
    /// worktree の一覧はここに載っているリポジトリだけを見に行く。
    /// 初めて見たときと、記録が古くなったときにだけ書く (理由は repoMemoryRefresh)。
    static func rememberRepo(_ ledger: inout LedgerFile, path: String, now: Int) {
        if let seen = ledger.repos[path], now - seen < repoMemoryRefresh { return }
        ledger.repos[path] = now
        guard ledger.repos.count > repoMemoryLimit else { return }
        // 溢れた分は「最後に見た」が古いものから落とす。
        // 同じ時刻で並んだときはパスで決着をつける (辞書の順は毎回変わるので、
        // それに任せると落ちるものが実行のたびに入れ替わる)
        let survivors = ledger.repos.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(repoMemoryLimit)
        ledger.repos = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
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
