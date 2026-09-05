import Foundation
import Model
import SQLite3
import Utility

/// Antigravity (agy) のセッション情報（タイトル・要約）を読み出す。
///
/// Antigravity は statusline でセッション名を送ってこないため、
/// 以下の優先順でセッションの目的・タイトルを解決する:
///   1. `conversation_summaries.db` (SQLite) の preview / title (AIが自動生成した要約)
///   2. `brain/<conversationId>/` 直下のアーティファクト (*.md) の H1 見出し
///   3. `transcript.jsonl` の最初の USER_INPUT (プロンプトの1行目)
public enum AntigravityMetadataReader {
    private static var cliHome: String {
        let home = EnvironmentSource.homeDirectory()
        return (home as NSString).appendingPathComponent(".gemini/antigravity-cli")
    }

    /// セッションIDからタイトルを解決する。見つからなければ nil を返す。
    public static func resolveTitle(conversationID: String) -> String? {
        guard !conversationID.isEmpty else { return nil }

        // 1. conversation_summaries.db (SQLite)
        if let title = readSummaryFromDB(conversationID: conversationID) {
            return title
        }

        // 2. アーティファクト (Plan 等の Markdown 見出し)
        if let title = readArtifactHeading(conversationID: conversationID) {
            return title
        }

        // 3. transcript.jsonl (最初のプロンプト)
        if let title = readFirstPrompt(conversationID: conversationID) {
            return title
        }

        return nil
    }

    // MARK: - 1. Database Reader

    private static func readSummaryFromDB(conversationID: String) -> String? {
        let dbPath = (cliHome as NSString).appendingPathComponent("conversation_summaries.db")
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT preview, title FROM conversation_summaries WHERE conversation_id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, conversationID, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let preview = sqlite3_column_text(stmt, 0).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !preview.isEmpty { return preview }

        let title = sqlite3_column_text(stmt, 1).map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        if !title.isEmpty { return title }

        return nil
    }

    // MARK: - 2. Artifact Heading Reader

    private static func readArtifactHeading(conversationID: String) -> String? {
        let brainDir = (cliHome as NSString).appendingPathComponent("brain/\(conversationID)")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: brainDir) else {
            return nil
        }

        // 生成された Markdown ファイルを探す（隠しファイルやシステム用フォルダはスキップ）
        for file in files where file.hasSuffix(".md") && !file.hasPrefix(".") {
            let path = (brainDir as NSString).appendingPathComponent(file)
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("# ") {
                    let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                    if !heading.isEmpty {
                        return truncate(heading, limit: 60)
                    }
                }
            }
        }
        return nil
    }

    // MARK: - 3. Transcript Prompt Reader

    /// 最初の `USER_INPUT` を探す。
    /// 最初の `USER_INPUT` を探す。
    ///
    /// ログファイル肥大化時の読み込み負荷を避けるため、先頭から段階的にウィンドウサイズを広げて探索する。
    private static func readFirstPrompt(conversationID: String) -> String? {
        let transcriptPath = (cliHome as NSString)
            .appendingPathComponent("brain/\(conversationID)/.system_generated/logs/transcript.jsonl")
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }

        var window = 16 * 1024
        let ceiling = 256 * 1024
        while true {
            guard (try? handle.seek(toOffset: 0)) != nil,
                  let data = try? handle.read(upToCount: window), !data.isEmpty
            else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            // 読み取り境界で分割された末尾の不完全な行は除外する
            var lines = text.components(separatedBy: "\n")
            let truncated = data.count == window
            if truncated, !lines.isEmpty { lines.removeLast() }

            for line in lines where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let type = json["type"] as? String, type == "USER_INPUT",
                      let raw = json["content"] as? String
                else { continue }
                return extractPromptSummary(from: raw)
            }
            guard truncated, window < ceiling else { return nil }
            window *= 2
        }
    }

    private static func extractPromptSummary(from raw: String) -> String? {
        var text = raw
        if let start = raw.range(of: "<USER_REQUEST>"),
            let end = raw.range(of: "</USER_REQUEST>", range: start.upperBound..<raw.endIndex) {
            text = String(raw[start.upperBound..<end.lowerBound])
        }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !trimmed.hasPrefix("<") {
                return truncate(trimmed, limit: 60)
            }
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        if text.count > limit {
            return String(text.prefix(limit - 3)) + "..."
        }
        return text
    }

    // MARK: - 4. Subagent Parent Resolver

    public struct SubagentInfo: Equatable {
        public var parentConversationID: String
        public var role: String?
        public var typeName: String?
        public var prompt: String?

        public init(parentConversationID: String, role: String? = nil,
                    typeName: String? = nil, prompt: String? = nil) {
            self.parentConversationID = parentConversationID
            self.role = role
            self.typeName = typeName
            self.prompt = prompt
        }
    }

    /// Antigravity のサブエージェントである場合、親の conversationID とメタデータ（Role/TypeName/Prompt）を解決する。
    ///
    /// 親セッションの transcript.jsonl 内にある `invoke_subagent` ログと照合して親子関係を特定する。
    /// 親セッションの候補一覧は呼び出し元から受け取る。
    public static func resolveSubagentInfo(conversationID: String,
                                           activeParentIDs: [String]) -> SubagentInfo? {
        guard !conversationID.isEmpty else { return nil }

        let parentCandidates = activeParentIDs.filter { $0 != conversationID }
        guard !parentCandidates.isEmpty else { return nil }

        let brainDir = (cliHome as NSString).appendingPathComponent("brain")
        for parentID in parentCandidates {
            let transcriptPath = (brainDir as NSString)
                .appendingPathComponent("\(parentID)/.system_generated/logs/transcript.jsonl")
            guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { continue }
            defer { try? handle.close() }

            guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { continue }
            let readSize: UInt64 = 65536 // 末尾 64KB
            let offset = fileSize > readSize ? fileSize - readSize : 0
            // ログ追記中のサイズ変動に対応するため、指定した読み込み範囲のみ取得する
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: Int(fileSize - offset))
            else { continue }
            // 切り出し境界でマルチバイト文字が欠損した場合にもデコード失敗しないよう String(decoding:as:) を使用する
            let chunk = String(decoding: data, as: UTF8.self)
            guard chunk.contains(conversationID) else { continue }

            if let info = parseSubagentInfo(from: chunk, childID: conversationID, parentID: parentID) {
                return info
            }
        }
        return nil
    }

    /// ログチャンクからサブエージェント情報を抽出する。
    /// JSON パースの負荷を抑えるため、キーワードで事前フィルタを行ってから対象行のみデコードする。
    private static func parseSubagentInfo(from chunk: String, childID: String, parentID: String) -> SubagentInfo? {
        let lines = chunk.components(separatedBy: .newlines)

        for index in lines.indices.reversed() {
            guard lines[index].contains(childID),
                  lines[index].contains("Created the following subagents"),
                  let step = decodeStep(lines[index]),
                  let contentStr = step["content"] as? String
            else { continue }

            // 親エージェントが grep や cat 等で自身のログを参照した際の出力行との誤判定を防ぐため、
            // 生成メッセージ直後に有効な JSON ブロックが存在することを確認する。
            if let block = createdSubagentsBlock(in: contentStr), block.contains(childID) {
                // invoke_subagent の引数配列には conversationId が含まれないため、
                // 生成通知ブロック内のインデックス順と対応付けてメタデータを解決する。
                let position = createdConversationIDs(in: block).firstIndex(of: childID)

                // 生成通知行より前のステップから invoke_subagent の呼び出し引数を逆順探索する
                for prevIndex in (0..<index).reversed() {
                    guard lines[prevIndex].contains("invoke_subagent"),
                          let prevStep = decodeStep(lines[prevIndex]),
                          let toolCalls = prevStep["tool_calls"] as? [[String: Any]] else { continue }
                    for call in toolCalls where call["name"] as? String == "invoke_subagent" {
                        guard let args = call["args"] as? [String: Any] else { continue }
                        // Subagents は JSON 文字列で来ることも配列で来ることもある
                        var requested: [[String: Any]] = []
                        if let raw = args["Subagents"] as? String,
                           let data = raw.data(using: .utf8),
                           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                            requested = array
                        } else if let array = args["Subagents"] as? [[String: Any]] {
                            requested = array
                        }
                        // インデックスが取得できない場合は、要求配列が単一要素の場合のみ採用する
                        // （複数要素時に誤った要素のメタデータが割り当てられるのを防ぐ）
                        let entry: [String: Any]?
                        if let position, position < requested.count {
                            entry = requested[position]
                        } else {
                            entry = requested.count == 1 ? requested[0] : nil
                        }
                        return SubagentInfo(
                            parentConversationID: parentID,
                            role: entry?["Role"] as? String,
                            typeName: entry?["TypeName"] as? String,
                            prompt: entry?["Prompt"] as? String)
                    }
                }
                return SubagentInfo(parentConversationID: parentID)
            }
        }
        return nil
    }

    /// transcript の1行を解く。窓の先頭は行の途中から始まるので、外れて普通
    private static func decodeStep(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 生成記録の JSON ブロックを切り出す。
    /// コマンド実行ログ等に含まれる同一文言と区別するため、直後が JSON 形式であることのみを対象とする。
    private static func createdSubagentsBlock(in content: String) -> Substring? {
        guard let phrase = content.range(of: "Created the following subagents:") else {
            return nil
        }
        let block = content[phrase.upperBound...]
        let head = block.drop { $0.isWhitespace }
        guard head.first == "{" || head.first == "[" else { return nil }
        return block
    }

    /// 生成記録に含まれる conversationId を出現順に抽出する。
    /// 呼び出し側の Subagents 配列とのインデックス突合に使用する。
    private static func createdConversationIDs(in content: Substring) -> [String] {
        let marker = "\"conversationId\""
        var ids: [String] = []
        var rest = content
        while let markerRange = rest.range(of: marker) {
            rest = rest[markerRange.upperBound...]
            let afterColon = rest.drop { $0.isWhitespace || $0 == ":" }
            guard afterColon.first == "\"" else { continue }
            let valueStart = afterColon.index(after: afterColon.startIndex)
            guard let closing = afterColon[valueStart...].firstIndex(of: "\"") else { break }
            ids.append(String(afterColon[valueStart..<closing]))
            rest = afterColon[afterColon.index(after: closing)...]
        }
        return ids
    }

    // MARK: - 5. Approval Probe

    /// 承認待ちステップの状態値 (Antigravity 内部 enum: CORTEX_STEP_STATUS_WAITING = 9)
    private static let waitingStepStatus = 9

    /// 会話データベースの保存先ディレクトリパス
    public static var conversationsDirectory: String {
        (cliHome as NSString).appendingPathComponent("conversations")
    }

    /// 指定した会話が現在ユーザーの承認待ちで停止しているかどうかを判定する。
    ///
    /// Antigravity は確認待ち遷移時のフックを発火しないため、会話 DB のステップ状態を直接確認する。
    /// WAL ファイルの一時的なフラッシュ等による読み取り失敗時に承認解除と誤認するのを防ぐため、
    /// 取得結果が不確定な場合は nil を返す。
    ///
    /// - Returns: 承認待ちなら true、非待機なら false、判定不能時は nil
    public static func isAwaitingApproval(conversationID: String) -> Bool? {
        guard !conversationID.isEmpty else { return nil }
        let dbPath = (conversationsDirectory as NSString)
            .appendingPathComponent("\(conversationID).db")

        // オープン失敗時もリソースリークを防ぐため確実に close する
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard opened == SQLITE_OK else { return nil }

        var stmt: OpaquePointer?
        let sql = "SELECT 1 FROM steps WHERE status = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(waitingStepStatus))
        switch sqlite3_step(stmt) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: return nil
        }
    }
}
