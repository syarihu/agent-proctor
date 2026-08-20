import Foundation

/// hooks から届く出来事を台帳に写す。
///
/// 台帳に載るのは、hooks が知らせてくれたセッションだけ。
/// proctor から worktree を作ることはないので、記録の入り口はここ1つになる。
public enum RecordHookEvent {
    /// 終了を取りこぼしたセッションの記録を捨てるまでの猶予
    public static let sessionTTL = 24 * 3600

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
    public static func touch(status: String, payload: HookPayload) throws {
        let top = GitClient.toplevel(from: payload.workingDirectory)
        guard !top.isEmpty else { return }  // git の外での実行は追いかけない

        let now = Int(Date().timeIntervalSince1970)
        try LedgerStore.withLock { ledger in
            // このフックを送ってきたセッションだけは掃除から外す。生きている証拠が
            // いま届いているのに消すのはおかしいし、--resume で開き直したときに
            // 「前のプロセスが死んでいる」を理由に落とすと、付けた名前も経過時間も
            // 引き継げず、別のタスクとして並び直してしまう
            let current = findTask(in: ledger, payload: payload).map { ledger.tasks[$0].id }
            pruneStaleSessions(&ledger, now: now, keeping: current)

            guard let index = findTask(in: ledger, payload: payload) else {
                try register(&ledger, status: status, payload: payload, top: top, now: now)
                return
            }

            if status == "clear" {
                // セッションが終わったら一覧から消す
                ledger.tasks.remove(at: index)
                return
            }

            // 変わったところだけ触る。何も変わらなければ LedgerStore.withLock が
            // 書き込みごと省くので、台帳の更新時刻が動かずサイドバーも数え直さない。
            // PostToolUse のように何度も飛んでくるイベントを受けられるのはこのため
            if ledger.tasks[index].status != status {
                ledger.tasks[index].status = status
                ledger.tasks[index].updatedAt = now
                // また動き出したら「確認した」は無かったことにする。
                // 次に終わったときは別の結果なので、改めて見てほしい
                if status == TaskStatus.running || status == TaskStatus.waiting {
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
            if let name = payload.sessionName, ledger.tasks[index].name != name {
                ledger.tasks[index].name = name
            }
            // 人が付けた名前。空文字で渡されたら外す (キーが無いときは触らない)
            if let tabTitle = payload.tabTitle {
                let trimmed = tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let value = trimmed.isEmpty ? nil : trimmed
                if ledger.tasks[index].title != value {
                    ledger.tasks[index].title = value
                }
            }
            if let model = payload.modelName, ledger.tasks[index].model != model {
                ledger.tasks[index].model = model
            }
            if let ctx = payload.contextPercent, ledger.tasks[index].contextPercent != ctx {
                ledger.tasks[index].contextPercent = ctx
            }
            // いま何をしているか。updatedAt はここでは動かさない
            // (ツールのたびに動かすと「経過」が 0 に戻り、並び順も落ち着かない)
            switch resolveActivity(status: status, payload: payload) {
            case .keep:
                break
            case .clear:
                ledger.tasks[index].activity = nil
            case .set(let text):
                ledger.tasks[index].activity = text
            }
            if status == TaskStatus.done || status == TaskStatus.failed,
               (ledger.tasks[index].subagents ?? 0) != 0 {
                // ターンが終わればサブエージェントは残らない。
                // 取りこぼしでずれた数をここで戻す。落ちて終わった (failed) ときも
                // SubagentStop は来ないので、同じように戻す
                ledger.tasks[index].subagents = 0
            }
        }
    }

    /// サブエージェントの増減を数える。
    ///
    /// PreToolUse(Task) で増やし、SubagentStop で減らす。取りこぼしても
    /// ターンの終わり (touch done) で 0 に戻すので、ずれたままにはならない。
    public static func countSubagent(delta: Int, payload: HookPayload) throws {
        try LedgerStore.withLock { ledger in
            guard let index = findTask(in: ledger, payload: payload) else { return }
            ledger.tasks[index].subagents = max(0, (ledger.tasks[index].subagents ?? 0) + delta)
            ledger.tasks[index].updatedAt = Int(Date().timeIntervalSince1970)
        }
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
    /// - ツールを叩いた (PostToolUse) → それを載せる
    /// - それ以外 → 触らない。確認待ちの間も、直前に何をしていたかは残したい
    static func resolveActivity(status: String, payload: HookPayload) -> ActivityUpdate {
        if status == TaskStatus.done || status == TaskStatus.failed { return .clear }
        if payload.isTurnStart { return .clear }
        if let activity = payload.toolActivity { return .set(activity) }
        return .keep
    }

    /// 新しく登録するのは、これから動き出すときだけにする。
    ///
    /// done や clear が単独で届くのは、終了処理が入れ違いになったときで
    /// (clear は同期・done は非同期なので追い越しうる)、ここで作ると
    /// 終わったはずのセッションが幽霊として一覧に戻ってしまう。
    ///
    /// セッションIDが取れないものも登録しない。次に来たときに照合できず、
    /// 呼ばれるたびに新しいタスクが積み上がる。
    private static func register(_ ledger: inout LedgerFile, status: String,
                                 payload: HookPayload, top: String, now: Int) throws {
        guard status == TaskStatus.running || status == TaskStatus.waiting,
              let session = payload.sessionID else { return }

        let branch = GitClient.currentBranch(top)
        let pid = EnvironmentSource.agentPID()
        ledger.tasks.append(TaskRecord(
            id: try TaskID.unique(
                base: TaskID.slugify(URL(fileURLWithPath: top).lastPathComponent),
                taken: ledger.tasks),
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
            // 消したあとなど)。そのときも何をしているかは載せておく
            activity: payload.toolActivity,
            title: payload.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            name: payload.sessionName,
            model: payload.modelName,
            contextPercent: payload.contextPercent))
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

    /// 終了を取りこぼしたセッションの記録を捨てる。
    ///
    /// SessionEnd が飛ばないまま終わることがあるため (タブごと閉じられた・殺された)、
    /// ここで掃除する。判断は2段構えになっている。
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
    static func pruneStaleSessions(
        _ ledger: inout LedgerFile, now: Int, keeping: String? = nil,
        isAlive: (Int, Int?) -> Bool = { ProcessLiveness.isAlive(pid: $0, startedAt: $1) }
    ) {
        ledger.tasks.removeAll { task in
            if let keeping, task.id == keeping { return false }
            if let pid = task.pid { return !isAlive(pid, task.pidStartedAt) }
            return task.status != TaskStatus.running && now - task.updatedAt >= sessionTTL
        }
    }
}
