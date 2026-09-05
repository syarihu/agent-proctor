import Foundation
import Model
import RepositoryLedger
import Utility

/// hooks と statusline から渡される JSON payload を解釈する。
/// Claude Code、Antigravity、Codex の各フォーマットに対応する。
public struct HookPayload {
    /// ツールの引数から操作内容を抽出する際のキー一覧（優先度順）。
    /// Antigravity は PascalCase のキーを使用するため、大文字小文字の両方を含める。
    /// Claude Code の Grep/Glob 等で検索語（pattern）より先にディレクトリパス（path）が選ばれるのを防ぐため、path は末尾に配置する。
    private static let detailKeys = [
        "command", "CommandLine",
        "file_path", "AbsolutePath", "TargetFile",
        "url", "Url",
        "pattern", "Pattern", "query", "Query",
        "description", "Description", "path", "toolSummary",
    ]

    /// ファイルパスを表すキー一覧
    private static let pathKeys: Set<String> = [
        "file_path", "AbsolutePath", "TargetFile", "path",
    ]

    /// 日付フォーマッタ。statusline の描画頻度が高いため共有インスタンスを使用する。
    private static let iso8601 = ISO8601DateFormatter()

    private let box: [String: Any]
    private let antigravitySubagentInfo: AntigravityMetadataReader.SubagentInfo?

    /// 受け取った JSON 辞書をラップする（ディスクアクセスは行わない）。
    public init(_ box: [String: Any] = [:]) {
        self.box = box
        self.antigravitySubagentInfo = nil
    }

    /// 解決済みのサブエージェント情報を引き継いでインスタンスを複製する。
    private init(_ box: [String: Any],
                 antigravitySubagentInfo: AntigravityMetadataReader.SubagentInfo?) {
        self.box = box
        self.antigravitySubagentInfo = antigravitySubagentInfo
    }

    /// Antigravity のサブエージェント関係を解決したインスタンスを返す。
    /// 親セッションのログ読み取り（I/O）を伴うため、台帳ロックの外で呼び出す。
    /// 既に台帳上で親子関係が記録されている場合はそれを再利用し、会話の進行によってログウィンドウから生成記録が外れた場合の見失いを防ぐ。
    public func resolvingAntigravitySubagent(in ledger: LedgerFile) -> HookPayload {
        guard agent == AgentKind.antigravity,
              let childID = rawSessionID, !childID.isEmpty else { return self }

        for task in ledger.tasks {
            guard let parent = task.sessionId, parent != childID,
                  let run = (task.subagentRuns ?? []).first(where: { $0.id == childID })
            else { continue }
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

    /// 標準入力から JSON を読み取って HookPayload を生成する。tty 入力時は空を返す。
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

    /// Claude の session_id および Antigravity の conversationId に対応する。
    /// Antigravity のサブエージェントの場合は親の conversationId を返す。
    public var sessionID: String? {
        if let subInfo = antigravitySubagentInfo {
            return subInfo.parentConversationID
        }
        return rawSessionID
    }

    /// 作業ディレクトリパス。取得できない場合はカレントディレクトリ。
    public var workingDirectory: String {
        if let cwd = box["cwd"] as? String, !cwd.isEmpty { return cwd }
        if let paths = box["workspacePaths"] as? [String], let first = paths.first {
            return first
        }
        return EnvironmentSource.currentDirectory()
    }

    public var message: String { box["message"] as? String ?? "" }

    /// 通知の種別 ("permission_prompt" / "idle_prompt" など)。
    public var notificationType: String? {
        (box["notification_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// フックのイベント名 ("UserPromptSubmit" / "Notification" / "Stop" など)。
    public var hookEventName: String? {
        (box["hook_event_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// ターン開始フックのイベント名定数
    public static let userPromptSubmitEvent = "UserPromptSubmit"

    /// ターン開始イベント（UserPromptSubmit）かどうか。
    public var isUserPromptSubmit: Bool {
        hookEventName == HookPayload.userPromptSubmitEvent
    }

    /// プロンプトの送信元種別 ("user", "system", "loop_wakeup" など)。
    public var promptSource: String? {
        (box["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// ユーザーによる入力でターンが開始されたかどうか
    public var isTurnStart: Bool {
        (box["prompt"] as? String).map { !$0.isEmpty } ?? false
    }

    /// ユーザーが明示的に設定した端末タブのタイトル。
    ///
    /// エージェントが自動生成する `session_name` より優先して表示するため分離して保持する。
    /// 空文字はタイトルの削除を意味し、キー未存在（nil）は既存値の維持を表す
    /// （タイトル解除時に古い名称が残存するのを防ぐ）。
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

    /// サブエージェントの個体識別子（agent_id または Antigravity の conversationId）。
    /// 子エージェント内で発火したイベントにのみ付与される（親の activity を上書きしないための識別に利用）。
    public var subagentID: String? {
        if antigravitySubagentInfo != nil {
            return rawSessionID
        }
        return (box["agent_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// サブエージェントの種別 (agent_type、Role名等)
    public var subagentType: String? {
        if let subInfo = antigravitySubagentInfo {
            return subInfo.role ?? subInfo.typeName
        }
        return (box["agent_type"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 起動されたサブエージェントの情報（ID、種別、プロンプト/説明）。
    /// Task/Agent ツールの PostToolUse の tool_response から抽出する。
    public var launchedSubagent: (id: String, type: String?, label: String?)? {
        if let response = box["tool_response"] as? [String: Any],
           let id = response["agentId"] as? String, !id.isEmpty {
            let label = (response["description"] as? String).flatMap {
                $0.isEmpty ? nil : HookPayload.condensed($0)
            }
            let type = ((box["tool_input"] as? [String: Any])?["subagent_type"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 }
            return (id, type, label)
        }
        if let subInfo = antigravitySubagentInfo, let id = rawSessionID {
            let label = subInfo.prompt.flatMap { HookPayload.condensed($0) }
            return (id, subInfo.role ?? subInfo.typeName, label)
        }
        return nil
    }

    /// ツールの引数から単一の文字列を抽出する（配列形式のコマンドにも対応）。
    static func plainText(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let parts = value as? [Any] {
            let joined = parts.compactMap { $0 as? String }.joined(separator: " ")
            return joined.isEmpty ? nil : joined
        }
        return nil
    }

    /// 文字列内の連続空白を単一スペースに平坦化し、上限長に切り詰める。
    static func condensed(_ text: String, limit: Int = 80) -> String {
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count <= limit ? flat : String(flat.prefix(limit))
    }

    /// ターン終了時のアシスタントの最終発言テキスト（地の文のみ抽出）。
    public var lastMessage: String? {
        guard let text = rawLastMessage else { return nil }
        let prose = HookPayload.plainProse(text)
        guard !prose.isEmpty else { return nil }
        return HookPayload.condensed(prose, limit: 120)
    }

    /// 最終発言テキストが payload に含まれていたかどうか。
    /// 取得結果が空文字や markdown 除去で nil になった場合と、キー自体が存在しなかった場合を区別するために使用する。
    public var carriesLastMessage: Bool { rawLastMessage != nil }

    private var rawLastMessage: String? {
        for key in ["last_assistant_message", "lastAssistantMessage"] {
            guard let text = box[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            return text
        }
        return nil
    }

    /// Markdown テキストから見出し、箇条書き、コードブロック等を除去して地の文のみを抽出する。
    static func plainProse(_ text: String) -> String {
        var kept: [String] = []
        var insideFence = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                insideFence.toggle()
                continue
            }
            if insideFence { continue }
            if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("|")
                || line.hasPrefix("---") || isListItem(line) {
                continue
            }
            kept.append(line)
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// 箇条書きの行（記号または番号付きリスト）かどうかを判定する。
    static func isListItem(_ line: String) -> Bool {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return true }
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty else { return false }
        let rest = line.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// エージェント種別（"claude" / "agy" / "codex"）を判定する。
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

    /// transcript ファイル名から Codex セッションかどうかを判定する
    private var isCodexTranscript: Bool {
        for key in ["transcript_path", "agent_transcript_path"] {
            guard let path = box[key] as? String, !path.isEmpty else { continue }
            if URL(fileURLWithPath: path).lastPathComponent.hasPrefix("rollout-") { return true }
        }
        return false
    }

    /// 指定されたエージェント名を付与した複製インスタンスを生成する
    public func naming(agent name: String?) -> HookPayload {
        guard let name, !name.isEmpty else { return self }
        var merged = box
        merged["agent"] = name
        return HookPayload(merged, antigravitySubagentInfo: antigravitySubagentInfo)
    }

    /// アカウント名 ("work", "personal" など)
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
            // Notification イベントの title は通知メッセージの見出しのためセッション名として採用しない
            if key == "title", hookEventName == "Notification" { continue }
            if let value = box[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        // Antigravity は payload にタイトルが含まれないため、メタデータから解決する
        if agent == AgentKind.antigravity, let session = sessionID {
            return AntigravityMetadataReader.resolveTitle(conversationID: session)
        }
        // Codex はセッション履歴 DB からタイトルを解決する
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
