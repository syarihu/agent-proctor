import Foundation

/// hooks と statusline が stdin に流してくる JSON。
///
/// Claude Code・Antigravity・Codex のどれからも呼ばれるので、キーの名前は
/// どの流儀も受ける。
public struct HookPayload {
    private let box: [String: Any]

    public init(_ box: [String: Any] = [:]) { self.box = box }

    /// 標準入力から読む。人が手で叩いたときは空になる。
    public static func fromStandardInput() -> HookPayload {
        guard isatty(0) == 0 else { return HookPayload() }
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return HookPayload() }
        return HookPayload(object)
    }

    /// Claude の session_id と Antigravity の conversationId / conversation_id に対応する。
    public var sessionID: String? {
        for key in ["session_id", "conversationId", "conversation_id"] {
            if let value = box[key] as? String, !value.isEmpty { return value }
        }
        return nil
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
        guard let raw = box["tool_name"] as? String, !raw.isEmpty else { return nil }
        // mcp__figma__get_screenshot のような長い名前は figma/get_screenshot に畳む
        var name = raw
        if name.hasPrefix("mcp__") { name.removeFirst("mcp__".count) }
        name = name.replacingOccurrences(of: "__", with: "/")

        let input = box["tool_input"] as? [String: Any] ?? [:]
        var detail: String?
        for key in ["command", "file_path", "url", "description"] {
            guard let value = HookPayload.plainText(input[key]) else { continue }
            // ファイルはパスを丸ごと出すと横に長い。名前だけで用は足りる
            detail = key == "file_path" ? URL(fileURLWithPath: value).lastPathComponent : value
            break
        }
        return HookPayload.condensed(detail.map { "\(name): \($0)" } ?? name)
    }

    /// サブエージェントの個体識別子 (`agent_id`)。
    ///
    /// **子の中で発火したフックにだけ付く。** つまりこれが入っているイベントは
    /// 親の手元で起きたことではないので、親の activity を塗り替えてはいけない。
    /// SubagentStart / SubagentStop でも同じ値が来るので、始まりと終わりが結べる
    public var subagentID: String? {
        (box["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// サブエージェントの種別 (`agent_type`)。"Explore" や独自エージェント名
    public var subagentType: String? {
        (box["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// いま起動されたサブエージェントの素性。
    ///
    /// Task/Agent ツールの `PostToolUse` の `tool_response` から取る。
    /// **`agent_id` と description が同じ payload に入っている唯一の場所**で、
    /// ここを読めば「どの子に何をさせたか」を余計な突き合わせなしに結べる。
    /// 非同期で起動される (`async_launched`) ので、子が終わるのを待たずに届く。
    public var launchedSubagent: (id: String, type: String?, label: String?)? {
        guard let response = box["tool_response"] as? [String: Any],
              let id = response["agentId"] as? String, !id.isEmpty else { return nil }
        let label = (response["description"] as? String).flatMap {
            $0.isEmpty ? nil : HookPayload.condensed($0)
        }
        // 種別は SubagentStart でも届くが、そちらを繋いでいない場合の受け皿として
        // ツールの引数からも拾っておく
        let type = ((box["tool_input"] as? [String: Any])?["subagent_type"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        return (id, type, label)
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
        return HookPayload(merged)
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
            } else if let date = ISO8601DateFormatter().date(from: raw) {
                resetsAt = Int(date.timeIntervalSince1970)
            }
        } else if let raw = dict["reset_time"] as? String, let date = ISO8601DateFormatter().date(from: raw) {
            resetsAt = Int(date.timeIntervalSince1970)
        } else if let resetIn = dict["reset_in_seconds"] as? Double {
            resetsAt = Int(Date().timeIntervalSince1970 + resetIn)
        } else if let resetIn = dict["reset_in_seconds"] as? Int {
            resetsAt = Int(Date().timeIntervalSince1970) + resetIn
        }

        return RateLimitWindow(usedPercent: rounded, resetsAt: resetsAt)
    }
}
