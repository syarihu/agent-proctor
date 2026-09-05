import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import Utility

/// hooks から通知されるセッションイベントを台帳に反映する。
public enum RecordHookEvent {
    /// 終了イベントを取りこぼしたセッション（PID 不明時）を自動破棄するまでの猶予期間（秒）
    public static let sessionTTL = 24 * 3600

    /// SubagentStop を取りこぼしたサブエージェントを自動回収するまでの猶予期間（秒）。
    /// 最終観測時刻（lastSeen）から起算して 10 分でタイムアウトとする。
    public static let subagentTTL = 10 * 60

    /// サブエージェントの生存時刻（lastSeenAt）を更新する最小間隔（秒）。
    /// 頻繁な台帳ファイル更新とそれに伴う UI 再集計を抑制する。
    public static let subagentHeartbeat = 60

    /// リポジトリの最終参照日時を更新する最小間隔（秒）。
    /// 台帳ファイルの不要な更新を抑えるため 24 時間間隔とする。
    public static let repoMemoryRefresh = 24 * 3600

    /// 台帳に記憶しておくリポジトリ数の上限。上限超過時は最終参照の古い順に削除する。
    public static let repoMemoryLimit = 50

    /// 終了したサブエージェントの ID を保持しておく期間（秒）。
    /// SubagentStop 直後に遅れて到着した PostToolUse イベント等によって完了済みサブエージェントが再生成されるのを防ぐ。
    public static let finishedSubagentTTL = 300

    /// Notification イベントの内容から反映すべきステータスを判定する。
    /// アイドル通知（idle_prompt）等は完了後の放置による誤った waiting マーク付与を防ぐため settled（確認待ち解除）を返す。
    /// 未知の種別の場合は見落とし防止のため waiting 側に倒す。
    /// - Returns: 遷移先ステータス文字列。状態変更を伴わないイベントなら nil
    public static func resolveNotification(_ payload: HookPayload) -> String? {
        guard let type = payload.notificationType else {
            // notificationType を送信しない古いクライアント向けのメッセージ文言フォールバック
            return payload.message.contains("waiting for your input")
                ? TaskStatus.settled : TaskStatus.waiting
        }
        switch type {
        case "permission_prompt",          // ツールの権限確認
             "elicitation_dialog",         // MCP サーバーからの入力要求
             "elicitation_url_dialog",     // MCP サーバーからのブラウザ操作要求
             "agent_needs_input",          // バックグラウンドセッションの入力待ち
             "quota_auto_resume_stale":    // レートリミット解除後の Enter 待ち
            return TaskStatus.waiting
        case "idle_prompt",                // 応答終了後の無操作
             "elicitation_complete",       // 入力フォームの送信・破棄
             "elicitation_response":       // 入力応答のサーバー送信完了
            return TaskStatus.settled
        case "auth_success", "agent_completed",
             "quota_auto_resume_fired", "quota_auto_resume_disabled":
            return nil
        default:
            return TaskStatus.waiting
        }
    }

    /// イベント処理の結果情報
    public struct Outcome {
        /// 台帳に記録されたステータス
        public let status: String
        /// 対象タスクに名前（title）が設定されていないかどうか
        public let unnamed: Bool

        public init(status: String, unnamed: Bool) {
            self.status = status
            self.unnamed = unnamed
        }
    }

    private static func isUnnamed(_ task: TaskRecord) -> Bool {
        (task.title ?? "").isEmpty
    }

    /// イベント状態を台帳に記録する。未登録のセッションであれば新規登録する。
    /// - Returns: 記録結果（実際のステータスと未命名フラグ）
    @discardableResult
    public static func record(status: String, payload raw: HookPayload) throws -> Outcome {
        let top = GitClient.toplevel(from: raw.workingDirectory)
        // git リポジトリ外の作業は追跡対象外とする
        guard !top.isEmpty else { return Outcome(status: status, unnamed: false) }

        let now = Int(Date().timeIntervalSince1970)

        // ロック時間を最小化するため、台帳の読み取りや外部情報（Git、メタデータ等）の解決はロック外で行う
        let snapshot = LedgerStore.read()
        let payload = raw.resolvingAntigravitySubagent(in: snapshot)
        let facts = SessionFacts(payload)
        let known = findTask(in: snapshot, payload: payload)
        let draft = known == nil
            ? draftRegistration(status: status, payload: payload, facts: facts,
                                top: top, now: now)
            : nil
        let moved = known.flatMap { relocation(of: snapshot.tasks[$0], to: top) }
        let repo = moved?.repo ?? known.map { snapshot.tasks[$0].repo } ?? draft?.repo

        return try LedgerStore.withLock { ledger in
            if let repo { rememberRepo(&ledger, path: repo, now: now) }
            // 現在イベントを送信してきたセッションは、プロセス再開時（--resume）等の競合による誤回収を防ぐため sweepLedger の対象から除外する
            let current = findTask(in: ledger, payload: payload).map { ledger.tasks[$0].id }
            sweepLedger(&ledger, now: now, keeping: current)

            // サブエージェントが親と結びつく前に一時的に単独セッションとして登録されていた場合、重複タスクを削除する
            if let subID = payload.subagentID, payload.sessionID != subID {
                ledger.tasks.removeAll { $0.sessionId == subID }
            }

            guard let index = findTask(in: ledger, payload: payload) else {
                let enrolled = try enroll(&ledger, draft: draft, top: top,
                                          agentKey: payload.agentKey)
                return Outcome(status: status,
                               unnamed: enrolled.map { isUnnamed($0) } ?? false)
            }

            if status == "clear" {
                if let subID = payload.subagentID {
                    removeSubagent(&ledger.tasks[index], id: subID, now: now)
                    settleHold(&ledger.tasks[index], now: now)
                    return .init(status: status, unnamed: isUnnamed(ledger.tasks[index]))
                }
                ledger.tasks.remove(at: index)
                return .init(status: status, unnamed: false)
            }

            // settled は確認待ち（waiting）の解除のみに使用する。
            // 子エージェント起因のイベントで親の確認待ちを誤って解除しないよう subagentID が nil であることを確認する。
            if status == TaskStatus.settled {
                guard payload.subagentID == nil,
                      ledger.tasks[index].status == TaskStatus.waiting else {
                    return .init(status: ledger.tasks[index].status,
                                 unnamed: isUnnamed(ledger.tasks[index]))
                }
                let stood = ClearAttention.standDown(&ledger.tasks[index])
                return .init(status: stood, unnamed: isUnnamed(ledger.tasks[index]))
            }

            // 既存セッションへの idle 反映は、会話圧縮や clear による意図しない待機中への遷移を防ぐためステータスは上書きしない。
            // ただし古い承認待ちメッセージ（request）は解除する。
            if status == TaskStatus.idle {
                rebind(&ledger.tasks[index], payload: payload, moved: moved)
                ledger.tasks[index].request = nil
                return .init(status: ledger.tasks[index].status,
                             unnamed: isUnnamed(ledger.tasks[index]))
            }

            // 子エージェント起因のイベント（PostToolUse / Stop 等）は親タスクの状態を直接変更せず子エージェント情報のみ更新する
            if let subID = payload.subagentID {
                if status == TaskStatus.done || status == TaskStatus.failed {
                    removeSubagent(&ledger.tasks[index], id: subID, now: now)
                    settleHold(&ledger.tasks[index], now: now)
                } else {
                    applySubagents(&ledger.tasks[index], payload: payload,
                                   status: status, now: now)
                }
                return .init(status: ledger.tasks[index].status,
                             unnamed: isUnnamed(ledger.tasks[index]))
            }

            // サブエージェントが実行中の場合、親タスクのステータスは running を維持し、done/failed を pendingStatus に保留する
            let hasLiveSubagents = !(ledger.tasks[index].subagentRuns ?? []).isEmpty
            let recorded: String
            if (status == TaskStatus.done || status == TaskStatus.failed), hasLiveSubagents {
                recorded = TaskStatus.running
                ledger.tasks[index].pendingStatus = status
            } else {
                recorded = status
                // 新しいターンが開始された場合は保留状態をクリアする
                if payload.isTurnStart {
                    ledger.tasks[index].pendingStatus = nil
                }
            }

            if ledger.tasks[index].status != recorded {
                ledger.tasks[index].status = recorded
                ledger.tasks[index].updatedAt = now
                // 再び実行中または確認待ちになった場合は、次回の完了通知を正常に行うため既読・開覧状態をリセットする
                if recorded == TaskStatus.running || recorded == TaskStatus.waiting {
                    ledger.tasks[index].seenAt = nil
                    ledger.tasks[index].openedAt = nil
                }
            }
            rebind(&ledger.tasks[index], payload: payload, moved: moved)
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
            // レートリミット情報は通常 statusline (`_stats`) 経由で取得するが、
            // Codex は statusline に対応していないためフックイベント経由でも更新を受け付ける。
            if let limits = facts.rateLimits {
                if ledger.tasks[index].rateLimits != limits {
                    ledger.tasks[index].rateLimits = limits
                }
                let key = payload.agentKey
                if ledger.agentRateLimits[key] != limits {
                    ledger.agentRateLimits[key] = limits
                }
            }
            // ツールの実行状況（activity）。ツール実行ごとに updatedAt を更新すると
            // 経過時間がリセットされ表示順序が不安定になるため、updatedAt は更新しない。
            // 子タスク完了待ちの親タスクで不要なツール表示が残り続けるのを防ぐため、
            // 記録用ステータス（recorded）ではなく受信イベント本来の status を用いて解決する。
            switch resolveActivity(status: status, payload: payload) {
            case .keep:
                break
            case .clear:
                ledger.tasks[index].activity = nil
            case .set(let text):
                ledger.tasks[index].activity = text
            }
            // 承認要求内容（request）。親タスクの状態との不整合を防ぐため、受信本来の status を用いて解決する
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
            // ターン終了時の最終発言テキスト（summary）の更新。
            // 子の完了待ちで保留された done イベント時もこの時点で記録しておく（最後の子が完了した際に表示可能とするため）。
            switch resolveSummary(status: status, payload: payload) {
            case .keep:
                break
            case .clear:
                if ledger.tasks[index].summary != nil {
                    ledger.tasks[index].summary = nil
                }
            case .set(let text):
                if ledger.tasks[index].summary != text {
                    ledger.tasks[index].summary = text
                }
            }
            applySubagents(&ledger.tasks[index], payload: payload, status: status, now: now)

            if (status == TaskStatus.done || status == TaskStatus.failed),
               !hasLiveSubagents, (ledger.tasks[index].subagents ?? 0) != 0 {
                // カウント値のみを管理するエージェントにおいて、SubagentStop を取りこぼした場合のズレをターン終了時にリセットする
                ledger.tasks[index].subagents = 0
            }
            return .init(status: recorded, unnamed: isUnnamed(ledger.tasks[index]))
        }
    }

    @available(*, deprecated, renamed: "record(status:payload:)")
    @discardableResult
    public static func touch(status: String, payload raw: HookPayload) throws -> Outcome {
        try record(status: status, payload: raw)
    }

    /// サブエージェントの増減を記録する。
    /// agent_id が存在する場合は個別管理（SubagentRun）し、存在しない場合はカウント値（subagents）を増減させる。
    public static func countSubagent(delta: Int, payload raw: HookPayload) throws {
        let payload = raw.resolvingAntigravitySubagent(in: LedgerStore.read())
        try LedgerStore.withLock { ledger in
            guard let index = findTask(in: ledger, payload: payload) else { return }
            let now = Int(Date().timeIntervalSince1970)
            pruneSubagents(&ledger.tasks[index], now: now)

            guard let id = payload.subagentID else {
                ledger.tasks[index].subagents =
                    max(0, (ledger.tasks[index].subagents ?? 0) + delta)
                ledger.tasks[index].updatedAt = now
                if ledger.tasks[index].subagents == 0 {
                    settleHold(&ledger.tasks[index], now: now)
                }
                return
            }

            // 個別管理の場合は、セッション経過時間の不要なリセットを防ぐため updatedAt を更新しない
            if delta > 0 {
                upsertSubagent(&ledger.tasks[index], id: id, now: now) { run in
                    if let type = payload.subagentType { run.type = type }
                }
            } else {
                removeSubagent(&ledger.tasks[index], id: id, now: now)
                if let count = ledger.tasks[index].subagents, count > 0 {
                    ledger.tasks[index].subagents = count - 1
                }
                // 全サブエージェント終了時に保留されたステータス（pendingStatus）があれば適用する
                settleHold(&ledger.tasks[index], now: now)
            }
        }
    }

    // MARK: - サブエージェント

    /// payload からサブエージェントの起動情報または実行中ツールの情報を更新する。
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
                // 承認待ち中のツールは未実行のため activity には反映しない
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
            if now - runs[index].lastSeen >= subagentHeartbeat {
                runs[index].lastSeenAt = now
            }
        } else {
            // 終了済みサブエージェント（遅延到着イベント）の再生成を防ぐ
            guard task.finishedSubagents?[id] == nil else { return }
            var run = SubagentRun(id: id, startedAt: now)
            edit(&run)
            runs.append(run)
        }
        task.subagentRuns = runs
    }

    /// サブエージェントを完了とし、遅延イベント抑制のため終了リスト（finishedSubagents）に記録する
    static func removeSubagent(_ task: inout TaskRecord, id: String, now: Int) {
        var runs = task.subagentRuns ?? []
        runs.removeAll { $0.id == id }
        task.subagentRuns = runs.isEmpty ? nil : runs

        var finished = task.finishedSubagents ?? [:]
        finished[id] = now
        task.finishedSubagents = finished
    }

    /// タイムアウトしたサブエージェントおよび期限切れの終了記録（finishedSubagents）を削除する。
    /// 稼働中サブエージェントの誤消去を防ぐため、開始時刻ではなく最終観測時刻（lastSeen）から経過時間を測る。
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

    /// 全サブエージェントが終了している場合、保留中のステータス（pendingStatus）を適用して確定する。
    /// 子エージェント起因の承認待ちをクリアするため request も nil にリセットする。
    static func settleHold(_ task: inout TaskRecord, now: Int) {
        guard task.subagentRuns == nil, let held = task.pendingStatus else { return }
        task.status = held
        task.pendingStatus = nil
        task.updatedAt = now
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

    /// ツール実行状況（activity）の更新判定。
    /// - ターン終了（done / failed）: 実行中ツールをクリア
    /// - ターン開始（UserPromptSubmit）: 前ターンのツール表示をクリア
    /// - サブエージェント実行ツール（agent_id 付き）: サブエージェント側で表示するため親側は変更しない
    /// - サブエージェント起動ツール: 親タスク側には反映しない
    /// - ツール実行（PostToolUse）: ツール表示を更新
    /// - その他: 直前のアクティビティを維持
    static func resolveActivity(status: String, payload: HookPayload) -> ActivityUpdate {
        if status == TaskStatus.done || status == TaskStatus.failed { return .clear }
        if payload.isTurnStart { return .clear }
        // 確認待ち（waiting）のツールは未実行の権限確認であるため、
        // 承認前のコマンドが実行中アクティビティとして表示されるのを防ぐ（request 側に記録する）。
        if status == TaskStatus.waiting { return .keep }
        // 子タスクのツール実行は同一 session_id で通知されるため、親タスクの表示汚染を防ぐ
        if payload.subagentID != nil { return .keep }
        if payload.launchedSubagent != nil { return .keep }
        if let activity = payload.toolActivity { return .set(activity) }
        return .keep
    }

    /// 承認要求メッセージ（request）の更新判定。
    /// - waiting に遷移した場合: 要求内容を反映
    /// - waiting 以外に遷移した場合: 承認完了等に伴いクリア（実行中タスクに古い承認要求が残存するのを防ぐ）
    /// - 子タスクの承認要求: 親タスクへの混入を防ぐため変更しない
    ///
    /// 承認待ちメッセージの更新種別
    enum RequestUpdate: Equatable {
        case keep
        case clear
        /// ツール実行情報から生成した詳細メッセージ（上書き優先）
        case set(String)
        /// 通知メッセージから取得したフォールバック文言（詳細メッセージが存在する場合は維持）
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

    /// 最終発言テキスト（summary）の更新種別
    enum SummaryUpdate: Equatable {
        case keep
        case clear
        case set(String)
    }

    /// ターン終了時の最終メッセージ（summary）を更新するかどうかを判定する。
    /// 完了・失敗時はメッセージがあれば設定し、本文があるにもかかわらず地の文が空だった場合は前回値をクリアする。
    /// 新規実行・確認待ちへの遷移時は前ターンの発言をクリアする。
    static func resolveSummary(status: String, payload: HookPayload) -> SummaryUpdate {
        if payload.subagentID != nil { return .keep }
        if status == TaskStatus.done || status == TaskStatus.failed {
            if let message = payload.lastMessage { return .set(message) }
            return payload.carriesLastMessage ? .clear : .keep
        }
        if status == TaskStatus.running || status == TaskStatus.waiting { return .clear }
        return .keep
    }

    /// 外部アクセス（ファイル読み取りや SQLite アクセス）を伴うメタデータ抽出結果を保持する構造体。
    /// 台帳ロックの保持時間を短縮するため、ロック取得前に一括抽出する。
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

    /// 新規登録用ドラフトを作成する（ロック外で呼び出し、Git コマンドを実行）。
    /// 終了系イベント単独での誤登録を防ぐため、稼働中ステータス（running / waiting / idle）のみを対象とする。
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
            activity: firstText(resolveActivity(status: status, payload: payload)),
            request: firstText(resolveRequest(status: status, payload: payload)),
            title: facts.tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
            name: facts.name,
            model: facts.model,
            contextPercent: facts.contextPercent,
            rateLimits: facts.rateLimits)
    }

    /// 新規タスクレコードを採番して台帳に追加する（ロック内で実行）。
    @discardableResult
    private static func enroll(_ ledger: inout LedgerFile, draft: TaskRecord?,
                               top: String, agentKey: String) throws -> TaskRecord? {
        guard var record = draft else { return nil }
        record.id = try TaskID.unique(
            base: TaskID.slugify(URL(fileURLWithPath: top).lastPathComponent),
            taken: ledger.tasks)
        ledger.tasks.append(record)
        if let limits = record.rateLimits {
            ledger.agentRateLimits[agentKey] = limits
        }
        return record
    }

    /// 作業ツリー移動時の追従情報。ID は変更せず worktree、repo、branch のみを更新する。
    struct Relocation {
        var worktree: String
        var repo: String
        var branch: String
    }

    /// 作業ツリーディレクトリが変更されている場合に更新情報を算出する（ロック外で呼び出し）。
    static func relocation(of record: TaskRecord, to top: String) -> Relocation? {
        guard record.worktree != top else { return nil }
        let branch = GitClient.currentBranch(top)
        return Relocation(worktree: top,
                          repo: GitClient.mainWorktree(from: top) ?? top,
                          branch: branch.isEmpty ? "-" : branch)
    }

    /// 既存レコードのプロセス ID、端末セッション、作業ディレクトリ等を現在の実行環境に結び直す。
    static func rebind(_ record: inout TaskRecord, payload: HookPayload,
                       moved: Relocation? = nil) {
        if let moved, record.worktree != moved.worktree {
            record.worktree = moved.worktree
            record.repo = moved.repo
            record.branch = moved.branch
        }
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

    /// セッションが実行されたリポジトリを台帳に記録する（24時間以上経過している場合のみ更新）。
    static func rememberRepo(_ ledger: inout LedgerFile, path: String, now: Int) {
        if let seen = ledger.repos[path], now - seen < repoMemoryRefresh { return }
        ledger.repos[path] = now
        guard ledger.repos.count > repoMemoryLimit else { return }
        let survivors = ledger.repos.sorted {
            $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
        }.prefix(repoMemoryLimit)
        ledger.repos = Dictionary(uniqueKeysWithValues: survivors.map { ($0.key, $0.value) })
    }

    /// hook のペイロード情報から対象のタスクを特定する。
    ///
    /// PROCTOR_ID → セッションID の順に照合する。
    /// 同一リポジトリで複数セッションが開かれる可能性があるため、作業ディレクトリのパスでは照合しない。
    static func findTask(in ledger: LedgerFile, payload: HookPayload) -> Int? {
        if let envID = EnvironmentSource.taskID(),
           let index = ledger.tasks.firstIndex(where: { $0.id == envID }) {
            return index
        }
        guard let session = payload.sessionID else { return nil }
        return ledger.tasks.firstIndex { $0.sessionId == session }
    }

    /// 台帳全体の不要なセッションおよびサブエージェント記録を整理する。
    ///
    /// 1. 終了イベントが届かずに終了したセッション記録の削除
    /// 2. タイムアウトしたサブエージェントおよび終了済み記録の削除
    /// 3. サブエージェントが完了した親タスクの保留状態の確定
    ///
    /// セッション終了判断:
    /// - PIDが記録されているもの: プロセスの生存確認を行い、プロセスが終了していれば状態に関わらず削除する。
    /// - PIDが未記録のもの: 実行中以外のタスクについてTTL経過で削除する。実行中のタスクは長時間ターンで更新時刻が進まない場合があるため、TTLでは削除しない。
    ///
    /// - Parameter keeping: 削除対象から除外するタスクID（現在イベント通知中のタスク）。
    /// - Parameter isAlive: プロセスの生死判定関数。テスト時に差し替え可能にする。
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
