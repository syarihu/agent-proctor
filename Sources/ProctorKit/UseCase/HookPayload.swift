import Foundation

/// hooks と statusline が stdin に流してくる JSON。
///
/// Claude Code・Antigravity・Codex のどれからも呼ばれるので、キーの名前は
/// どの流儀も受ける。
public struct HookPayload {
    /// ツールの引数から「何をしているか」を取るときに見る鍵。**上から順**。
    ///
    /// **Antigravity の引数は PascalCase。** 小文字だけ並べていると何ひとつ
    /// 当たらず、最後の toolSummary ("File edit" など) に落ちて、どのファイルを
    /// 触ったのか分からない行になる。
    ///
    /// **`path` は最後に置く。** Claude Code の Grep / Glob では `path` が
    /// 「探す場所」で、載せたいのは `pattern` のほう。先に置くと検索語ではなく
    /// ディレクトリ名が出て、ファイル名のように見えてしまう。
    ///
    /// 組み立て直さないのは、ここがツール1回ごとに通る道だから
    private static let detailKeys = [
        "command", "CommandLine",
        "file_path", "AbsolutePath", "TargetFile",
        "url", "Url",
        "pattern", "Pattern", "query", "Query",
        "description", "Description", "path", "toolSummary",
    ]

    /// このうちファイルを指すもの
    private static let pathKeys: Set<String> = [
        "file_path", "AbsolutePath", "TargetFile", "path",
    ]

    /// 日付の読み取りは1つを使い回す。
    /// `ISO8601DateFormatter` の生成はそれ自体が高く、ここは statusline から
    /// 描画のたびに通る。使うのは読み取りだけなので、共有しても困らない
    private static let iso8601 = ISO8601DateFormatter()

    private let box: [String: Any]
    private let antigravitySubagentInfo: AntigravityMetadataReader.SubagentInfo?

    /// **ここでは何も読みに行かない。** 受け取った JSON を包むだけ。
    ///
    /// 親子の解決 (`resolvingAntigravitySubagent`) は台帳と transcript を読む
    /// 仕事なので、いつ・どこで払うかを呼ぶ側が決められるように分けてある。
    /// 生成のたびに黙ってディスクを触ると、`naming(agent:)` のような
    /// 写しを作るだけの操作にまで I/O が付いて回る
    public init(_ box: [String: Any] = [:]) {
        self.box = box
        self.antigravitySubagentInfo = nil
    }

    /// 解決済みの素性を引き継いで写しを作る。
    private init(_ box: [String: Any],
                 antigravitySubagentInfo: AntigravityMetadataReader.SubagentInfo?) {
        self.box = box
        self.antigravitySubagentInfo = antigravitySubagentInfo
    }

    /// Antigravity のサブエージェントかどうかを見極めた写しを返す。
    ///
    /// **ロックを取る前に呼ぶこと。** 親のログを読みに行くので、ロックの中で
    /// やると台帳に触る全員を待たせる。
    ///
    /// **hooks から台帳を触る UseCase は、必ずここを通すこと。** 呼び忘れても
    /// 型は何も言わないし動きもする (親子が結ばれず、子が独立した行として
    /// 生えるだけ)。新しい入り口を足すときは忘れやすいので気を付ける。
    /// いま通しているのは `RecordHookEvent.touch` / `.countSubagent` と
    /// `RecordSessionStats.run` の3つ。
    ///
    /// 手順は2段。まず台帳を見て、既にどこかの子として載っていればそれを使う。
    /// **一度結び付いた親子は離さない**ためで、親のログを遡る手だけに頼ると、
    /// 親が喋り続けて生成の記録が読み取り窓から流れ出た瞬間に見失い、
    /// 走っている最中の子が独立したセッションとして生え直してしまう。
    /// 台帳に載っていなければ、そこで初めて親のログを読みに行く。
    public func resolvingAntigravitySubagent(in ledger: LedgerFile) -> HookPayload {
        guard agent == AgentKind.antigravity,
              let childID = rawSessionID, !childID.isEmpty else { return self }

        for task in ledger.tasks {
            guard let parent = task.sessionId, parent != childID,
                  let run = (task.subagentRuns ?? []).first(where: { $0.id == childID })
            else { continue }
            // 素性は最初に結んだときのものを引き継ぐ。生成の記録はもう読めない
            return HookPayload(box, antigravitySubagentInfo: .init(
                parentConversationID: parent, role: run.type, prompt: run.label))
        }

        let candidates = ledger.tasks.compactMap { task -> String? in
            guard task.agent == AgentKind.antigravity, let sid = task.sessionId,
                  sid != childID else { return nil }
            return sid
        }
        guard !candidates.isEmpty else { return self }
        return HookPayload(box, antigravitySubagentInfo:
            AntigravityMetadataReader.resolveSubagentInfo(
                conversationID: childID, activeParentIDs: candidates))
    }

    /// 標準入力から読む。人が手で叩いたときは空になる。
    public static func fromStandardInput() -> HookPayload {
        guard isatty(0) == 0 else { return HookPayload() }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return HookPayload() }
        return HookPayload(object)
    }

    private var rawSessionID: String? {
        for key in ["session_id", "conversationId", "conversation_id"] {
            if let value = box[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Claude の session_id と Antigravity の conversationId / conversation_id に対応する。
    /// Antigravity のサブエージェントの場合は親の conversationId を返す。
    public var sessionID: String? {
        if let subInfo = antigravitySubagentInfo {
            return subInfo.parentConversationID
        }
        return rawSessionID
    }

    /// 作業ディレクトリ。分からなければ今いる場所。
    public var workingDirectory: String {
        if let cwd = box["cwd"] as? String, !cwd.isEmpty { return cwd }
        if let paths = box["workspacePaths"] as? [String], let first = paths.first {
            return first
        }
        return EnvironmentSource.currentDirectory()
    }

    public var message: String { box["message"] as? String ?? "" }

    /// 通知の種別 ("permission_prompt" / "idle_prompt" など)。
    ///
    /// **文言 (`message`) ではなくこちらで判じる。** あちらは版で変わるし、
    /// 公式に決まっているのは種別のほうだけ。持っていない版もあるので、
    /// 無いときの受け皿は呼ぶ側が用意する
    public var notificationType: String? {
        (box["notification_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// ターンの始まり (UserPromptSubmit)。人が何か打った直後だけ真になる。
    /// 空のプロンプトは数えない (前のターンの活動を消してしまうため)
    public var isTurnStart: Bool {
        (box["prompt"] as? String).map { !$0.isEmpty } ?? false
    }

    /// 人が明示的に付けた名前。端末のタブに付けたタイトルを hooks が乗せてくる。
    ///
    /// エージェントが自分で付ける `session_name` とは別に持つ。あちらは会話から
    /// 勝手に決まるもので、こちらは人が「この作業はこれ」と決めたもの。
    /// 一覧に出すのは後者を先にしたいので、混ぜずに分けておく。
    ///
    /// **空文字は「消す」の意味**で、キーが無いのは「そのまま」。
    /// タブのタイトルを外したときに、古い名前が残らないようにするため。
    public var tabTitle: String? { box["tab_title"] as? String }

    /// いま触っているツールの表示ラベル。PostToolUse の payload から組む。
    ///
    /// 例: Bash -> "Bash: npm test" / Edit -> "Edit: TaskStore.swift"
    ///     mcp__figma__get_screenshot -> "figma/get_screenshot: ..."
    ///
    /// ツール名が無いイベント (UserPromptSubmit や Stop) では nil を返す。
    /// 呼ぶ側が「触らない」と「消す」を区別できるよう、空文字は返さない。
    ///
    /// 組み立てをここに置くのは、フックを書く側に写させないため。
    /// 同じ形の payload を投げるエージェントなら、繋ぐだけで同じ行が出る。
    public var toolActivity: String? {
        let raw: String?
        let input: [String: Any]
        if let toolName = box["tool_name"] as? String, !toolName.isEmpty {
            raw = toolName
            input = box["tool_input"] as? [String: Any] ?? [:]
        } else if let toolCall = box["toolCall"] as? [String: Any],
                  let name = toolCall["name"] as? String, !name.isEmpty {
            raw = name
            input = toolCall["args"] as? [String: Any] ?? [:]
        } else {
            return nil
        }
        guard let raw else { return nil }

        // mcp__figma__get_screenshot のような長い名前は figma/get_screenshot に畳む
        var name = raw
        if name.hasPrefix("mcp__") { name.removeFirst("mcp__".count) }
        name = name.replacingOccurrences(of: "__", with: "/")

        var detail: String?
        for key in HookPayload.detailKeys {
            guard let value = HookPayload.plainText(input[key]) else { continue }
            // ファイルはパスを丸ごと出すと横に長い。名前だけで用は足りる
            detail = HookPayload.pathKeys.contains(key)
                ? URL(fileURLWithPath: value).lastPathComponent : value
            break
        }
        return HookPayload.condensed(detail.map { "\(name): \($0)" } ?? name)
    }

    /// サブエージェントの個体識別子 (`agent_id` または Antigravity の conversationId)。
    ///
    /// **子の中で発火したフックにだけ付く。** つまりこれが入っているイベントは
    /// 親の手元で起きたことではないので、親の activity を塗り替えてはいけない。
    /// SubagentStart / SubagentStop でも同じ値が来るので、始まりと終わりが結べる
    public var subagentID: String? {
        if antigravitySubagentInfo != nil {
            return rawSessionID
        }
        return (box["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// サブエージェントの種別 (`agent_type`)。"Explore" や独自エージェント名、Antigravity の Role
    public var subagentType: String? {
        if let subInfo = antigravitySubagentInfo {
            return subInfo.role ?? subInfo.typeName
        }
        return (box["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// いま起動されたサブエージェントの素性。
    ///
    /// Task/Agent ツールの `PostToolUse` の `tool_response` から取る。
    /// **`agent_id` と description が同じ payload に入っている唯一の場所**で、
    /// ここを読めば「どの子に何をさせたか」を余計な突き合わせなしに結べる。
    /// 非同期で起動される (`async_launched`) ので、子が終わるのを待たずに届く。
    public var launchedSubagent: (id: String, type: String?, label: String?)? {
        if let response = box["tool_response"] as? [String: Any],
           let id = response["agentId"] as? String, !id.isEmpty {
            let label = (response["description"] as? String).flatMap {
                $0.isEmpty ? nil : HookPayload.condensed($0)
            }
            // 種別は SubagentStart でも届くが、そちらを繋いでいない場合の受け皿として
            // ツールの引数からも拾っておく
            let type = ((box["tool_input"] as? [String: Any])?["subagent_type"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return (id, type, label)
        }
        // Antigravity のサブエージェントの場合、自身が起動された時の prompt をラベルとして載せる
        if let subInfo = antigravitySubagentInfo, let id = rawSessionID {
            let label = subInfo.prompt.flatMap { HookPayload.condensed($0) }
            return (id, subInfo.role ?? subInfo.typeName, label)
        }
        return nil
    }

    /// ツールの引数から1つの文字列を取り出す。
    ///
    /// **command は文字列とは限らない。** codex のシェルは `["bash", "-lc", "…"]` の
    /// ように配列で渡してくるので、文字列だけを見ていると
    /// 「Bash」とだけ出て何を叩いているのか分からない行になる
    static func plainText(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let parts = value as? [Any] {
            let joined = parts.compactMap { $0 as? String }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// 台帳に載せる前に1行へ均す。command にはヒアドキュメントが丸ごと
    /// 入ってくることがあり、そのまま持つと台帳が肥大化する
    static func condensed(_ text: String, limit: Int = 80) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit))
    }

    /// 終わったターンが最後に言ったこと。
    ///
    /// Claude Code の `Stop` / `StopFailure` / `SubagentStop` に入っている。
    /// **transcript を読みに行かずに済むのがここを使う理由**で、Claude Code 自身が
    /// そう言っている ("Avoids the need to read and parse the transcript file")。
    /// 持ってこないエージェントでは nil のまま通るので、繋ぎ方は変えなくていい。
    ///
    /// 載せるのは地の文だけを1行に均したもの。エージェントの返事は markdown なので、
    /// そのまま持つと `**` や `##` が記号のまま一覧に出る。
    /// 長さは activity より緩くしてある (あちらはツール名、こちらは文)
    public var lastMessage: String? {
        for key in ["last_assistant_message", "lastAssistantMessage"] {
            guard let text = box[key] as? String else { continue }
            let prose = HookPayload.plainProse(text)
            if !prose.isEmpty { return HookPayload.condensed(prose, limit: 120) }
        }
        return nil
    }

    /// markdown を人の文に均す。**要るのは地の文だけ。**
    ///
    /// 見出し・箇条書き・表・引用・コードブロックは文章の骨組みで、1行に潰すと
    /// 記号だけが残って読めなくなる (「## 結論 - A - B」)。行ごと落とす。
    /// 強調とコード記法は文の途中に出るので、記号だけ外して中身は残す。
    ///
    /// 箇条書きの判定に**後ろの空白まで見る**のは、`**結論**` のように
    /// 強調で書き出した段落を巻き添えにしないため
    static func plainProse(_ text: String) -> String {
        var kept: [String] = []
        // **コードは開きと閉じで挟まれるので、1行ずつの判定では捨てられない。**
        // フェンスの行だけを落とすと中身がそのまま残り、短い返事では
        // 2行目がまるごとコードで埋まる ("直したのだ。 let policy = …")
        var insideFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // 開きと閉じは同じ形なので、出会うたびに裏返す。
            // 閉じないまま終わる返事では、そこから先が丸ごと落ちる
            // (中途半端に開いたコードを地の文として読ませるよりはよい)
            if line.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if line.hasPrefix("#") || line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.hasPrefix(">") || line.hasPrefix("|") || line.hasPrefix("---") {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// セッションを動かしているエージェント ("claude" / "agy" / "codex")。
    ///
    /// **Codex は Claude Code とほとんど同じ形の payload を送ってくる**
    /// (`session_id` も `cwd` も `tool_name` も同じ名前)。キーの有無では
    /// 見分けが付かないので、記録の置き場所で判じる。それも当てにならない
    /// 場合に備えて、hooks 側から `--agent=codex` で名乗れるようにしてある
    public var agent: String? {
        if let explicit = box["agent"] as? String, !explicit.isEmpty { return explicit }
        if box["conversationId"] != nil || box["conversation_id"] != nil
            || box["transcriptPath"] != nil || box["artifactDirectoryPath"] != nil {
            return AgentKind.antigravity
        }
        if isCodexTranscript { return AgentKind.codex }
        if box["session_id"] != nil { return AgentKind.claude }
        return nil
    }

    /// transcript が codex の rollout かどうか。
    ///
    /// codex は `~/.codex/sessions/<年>/<月>/<日>/rollout-<日時>-<id>.jsonl` に
    /// 会話を積む。Claude Code のほうは `~/.claude/projects/` の下なので、
    /// ファイル名の頭 (`rollout-`) だけで取り違えずに分けられる
    private var isCodexTranscript: Bool {
        for key in ["transcript_path", "agent_transcript_path"] {
            guard let path = box[key] as? String, !path.isEmpty else { continue }
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") { return true }
        }
        return false
    }

    /// hooks を呼ぶ側から名乗られたエージェントを混ぜた payload を返す。
    ///
    /// 元の中身は触らない。`agent` は payload に無いものを外から足す唯一の項目なので、
    /// 読み出し側 (`agent` / `agentKey`) がどちらの経路も同じように扱えるよう、
    /// 箱に入れた形に揃えてから渡す
    public func naming(agent name: String?) -> HookPayload {
        guard let name, !name.isEmpty else { return self }
        var merged = box
        merged["agent"] = name
        // 解決済みの素性は持ち越す。作り直すたびに読み直していては、
        // 名乗りを足すだけの操作にディスクの読み出しが付いて回る
        return HookPayload(merged, antigravitySubagentInfo: antigravitySubagentInfo)
    }

    /// アカウント名 ("work", "personal" など)。
    public var account: String? {
        for key in ["account", "account_name", "profile", "org"] {
            if let value = box[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        if let configDir = box["config_dir"] as? String {
            let last = URL(fileURLWithPath: configDir).lastPathComponent
            if last != ".claude" && last != ".gemini" && last != ".codex" && !last.isEmpty {
                return last.replacingOccurrences(of: ".claude-", with: "")
                    .replacingOccurrences(of: ".claude_", with: "")
                    .replacingOccurrences(of: ".gemini-", with: "")
                    .replacingOccurrences(of: ".gemini_", with: "")
                    .replacingOccurrences(of: ".codex-", with: "")
                    .replacingOccurrences(of: ".codex_", with: "")
            }
        }
        return nil
    }

    /// アカウント情報を含む台帳集約用のキー ("claude", "claude:work", "agy:personal" など)
    public var agentKey: String {
        let baseAgent = agent ?? AgentKind.claude
        if let account, !account.isEmpty {
            return "\(baseAgent):\(account)"
        }
        return baseAgent
    }

    public var sessionName: String? {
        for key in ["session_name", "title", "session_title", "preview"] {
            if let value = box[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        // Antigravity は payload にタイトルが入ってこないため、DB/アーティファクト/プロンプトから解決する
        if agent == AgentKind.antigravity, let session = sessionID {
            return AntigravityMetadataReader.resolveTitle(conversationID: session)
        }
        // Codex も同じで、名前は payload に載ってこない。あちらが自分で
        // 持っているセッション台帳 (threads 表) から引く
        if agent == AgentKind.codex, let session = sessionID {
            return CodexMetadataReader.resolveTitle(sessionID: session)
        }
        return nil
    }

    public var modelName: String? {
        if let nested = box["model"] as? [String: Any] {
            return (nested["display_name"] as? String)
                ?? (nested["id"] as? String)
                ?? (nested["name"] as? String)
        }
        if let value = box["model"] as? String, !value.isEmpty { return value }
        return nil
    }

    /// コンテキスト使用率 (%)。四捨五入した整数で返す。
    public var contextPercent: Int? {
        var percent: Double?
        if let nested = box["context_window"] as? [String: Any] {
            if let used = nested["used_percentage"] as? Double {
                percent = used
            } else if let current = nested["current"] as? Double,
                      let limit = nested["limit"] as? Double, limit > 0 {
                percent = current / limit * 100
            }
        } else if let value = box["context_window"] as? Double {
            percent = value
        }
        if percent == nil { return codexUsage?.contextPercent }
        return percent.map { Int($0.rounded()) }
    }

    /// Codex が rollout に残している消費量。
    ///
    /// Codex には statusline が無く、文脈量もレートリミットも hooks には来ない。
    /// 他のエージェントでは statusline (`_stats`) が運んでくるものを、
    /// ここだけは記録から拾い直している
    private var codexUsage: CodexMetadataReader.Usage? {
        guard agent == AgentKind.codex, let session = sessionID else { return nil }
        return CodexMetadataReader.resolveUsage(
            sessionID: session, transcriptPath: box["transcript_path"] as? String)
    }

    /// レートリミット（5時間枠・7日間枠）情報。statusline から届く。
    /// Codex だけは statusline が無いので、あちらの記録から拾ったものを使う
    public var rateLimits: AgentRateLimits? {
        if let limits = codexUsage?.rateLimits { return limits }
        let quota = box["quota"] as? [String: Any] ?? [:]
        let rateLimits = box["rate_limits"] as? [String: Any] ?? [:]

        let modelIdLower = (modelName ?? "").lowercased()
        let is3P = modelIdLower.contains("claude") || modelIdLower.contains("opus")
            || modelIdLower.contains("sonnet") || modelIdLower.contains("haiku")
            || modelIdLower.contains("gpt") || modelIdLower.contains("3p")

        let fiveDict: [String: Any]?
        let weekDict: [String: Any]?

        if is3P {
            fiveDict = (quota["3p-5h"] as? [String: Any])
                ?? (rateLimits["five_hour"] as? [String: Any])
                ?? (quota["five_hour"] as? [String: Any])
                ?? (quota["gemini-5h"] as? [String: Any])
            weekDict = (quota["3p-weekly"] as? [String: Any])
                ?? (rateLimits["seven_day"] as? [String: Any])
                ?? (quota["seven_day"] as? [String: Any])
                ?? (quota["gemini-weekly"] as? [String: Any])
        } else {
            fiveDict = (quota["gemini-5h"] as? [String: Any])
                ?? (rateLimits["five_hour"] as? [String: Any])
                ?? (quota["five_hour"] as? [String: Any])
                ?? (quota["3p-5h"] as? [String: Any])
            weekDict = (quota["gemini-weekly"] as? [String: Any])
                ?? (rateLimits["seven_day"] as? [String: Any])
                ?? (quota["seven_day"] as? [String: Any])
                ?? (quota["3p-weekly"] as? [String: Any])
        }

        let five = parseRateLimitWindow(from: fiveDict)
        let week = parseRateLimitWindow(from: weekDict)

        if five == nil && week == nil {
            return nil
        }
        return AgentRateLimits(fiveHour: five, sevenDay: week)
    }

    private func parseRateLimitWindow(from dict: [String: Any]?) -> RateLimitWindow? {
        guard let dict else { return nil }

        var percent: Double?
        if let p = dict["used_percentage"] as? Double {
            percent = p
        } else if let p = dict["used_percentage"] as? Int {
            percent = Double(p)
        } else if let rem = dict["remaining_fraction"] as? Double {
            percent = (1.0 - rem) * 100
        } else if let rem = dict["remaining"] as? Double, let limit = dict["limit"] as? Double, limit > 0 {
            percent = (limit - rem) / limit * 100
        } else if let rem = dict["remaining"] as? Int, let limit = dict["limit"] as? Int, limit > 0 {
            percent = Double(limit - rem) / Double(limit) * 100
        }

        guard let finalPct = percent else { return nil }
        let rounded = max(0, min(100, Int(finalPct.rounded())))

        var resetsAt: Int?
        if let raw = dict["resets_at"] as? Int {
            resetsAt = raw
        } else if let raw = dict["resets_at"] as? Double {
            resetsAt = Int(raw)
        } else if let raw = dict["resets_at"] as? String {
            if let epoch = Int(raw) {
                resetsAt = epoch
            } else if let epochDouble = Double(raw) {
                resetsAt = Int(epochDouble)
            } else if let date = HookPayload.iso8601.date(from: raw) {
                resetsAt = Int(date.timeIntervalSince1970)
            }
        } else if let raw = dict["reset_time"] as? String, let date = HookPayload.iso8601.date(from: raw) {
            resetsAt = Int(date.timeIntervalSince1970)
        } else if let resetIn = dict["reset_in_seconds"] as? Double {
            resetsAt = Int(Date().timeIntervalSince1970 + resetIn)
        } else if let resetIn = dict["reset_in_seconds"] as? Int {
            resetsAt = Int(Date().timeIntervalSince1970) + resetIn
        }

        return RateLimitWindow(usedPercent: rounded, resetsAt: resetsAt)
    }
}
