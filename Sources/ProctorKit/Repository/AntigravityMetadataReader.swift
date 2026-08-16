import Foundation
import SQLite3

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

    private static func readFirstPrompt(conversationID: String) -> String? {
        let transcriptPath = (cliHome as NSString)
            .appendingPathComponent("brain/\(conversationID)/.system_generated/logs/transcript.jsonl")
        guard FileManager.default.fileExists(atPath: transcriptPath),
              let content = try? String(contentsOfFile: transcriptPath, encoding: .utf8)
        else { return nil }

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String, type == "USER_INPUT",
                  let raw = json["content"] as? String
            else { continue }

            return extractPromptSummary(from: raw)
        }
        return nil
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
}
