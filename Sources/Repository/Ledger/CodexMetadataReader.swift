import Foundation
import Model
import SQLite3
import Utility

/// Codex CLI (codex) のセッション情報を読み出す。
///
/// Codex には statusline による外部連携口がないため、以下からメタデータを取得する:
///   - `~/.codex/state_<n>.sqlite` の `threads` テーブル: 見出し・rollout パス
///   - rollout の jsonl: `token_count` イベント (コンテキスト消費量・レートリミット)
public enum CodexMetadataReader {
    /// rollout から取得したセッション消費量。
    public struct Usage {
        public var contextPercent: Int?
        public var rateLimits: AgentRateLimits?
    }

    private static var codexHome: String {
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["CODEX_HOME"], !dir.isEmpty { return dir }
        return (EnvironmentSource.homeDirectory() as NSString).appendingPathComponent(".codex")
    }

    // MARK: - 見出し

    /// セッションIDから見出しを解決する。見つからなければ nil。
    /// 優先順位: ユーザー設定名 → 自動生成タイトル → 最初のプロンプト。
    public static func resolveTitle(sessionID: String) -> String? {
        guard let row = thread(sessionID: sessionID) else { return nil }
        for candidate in [row.name, row.title, row.firstUserMessage] {
            if let headline = firstLine(of: candidate) { return headline }
        }
        return nil
    }

    // MARK: - 消費量

    /// セッションの文脈使用率とレートリミットを rollout から取得する。
    /// プロセス実行中の重複 I/O を避けるためメモリキャッシュする。
    private static var usageCache: [String: Usage?] = [:]

    /// - Parameter transcriptPath: payload の `transcript_path`。指定がある場合は SQLite を開かずに直接参照する。
    public static func resolveUsage(sessionID: String, transcriptPath: String? = nil) -> Usage? {
        if let cached = usageCache[sessionID] { return cached }
        let usage = readUsage(sessionID: sessionID, transcriptPath: transcriptPath)
        usageCache[sessionID] = usage
        return usage
    }

    private static func readUsage(sessionID: String, transcriptPath: String?) -> Usage? {
        guard let rollout = rolloutPath(sessionID: sessionID, transcriptPath: transcriptPath),
              let event = lastTokenCount(inRollout: rollout)
        else { return nil }

        let info = event["info"] as? [String: Any]
        let usage = Usage(contextPercent: contextPercent(from: info),
                          rateLimits: rateLimits(from: event["rate_limits"] as? [String: Any]))
        if usage.contextPercent == nil && usage.rateLimits == nil { return nil }
        return usage
    }

    /// 文脈使用率の計算。現在のウィンドウ占有率を取得するため直前の往復 (`last_token_usage`) を参照する。
    private static func contextPercent(from info: [String: Any]?) -> Int? {
        guard let info,
              let window = number(info["model_context_window"]), window > 0,
              let last = info["last_token_usage"] as? [String: Any],
              let used = number(last["total_tokens"])
        else { return nil }
        return max(0, min(100, Int((used / window * 100).rounded())))
    }

    /// レートリミット情報のパース。`window_minutes` に応じて5時間枠または週次枠に振り分ける。
    private static func rateLimits(from dict: [String: Any]?) -> AgentRateLimits? {
        guard let dict else { return nil }
        var five: RateLimitWindow?
        var week: RateLimitWindow?
        for key in ["primary", "secondary"] {
            guard let entry = dict[key] as? [String: Any],
                  let percent = number(entry["used_percent"]),
                  let minutes = number(entry["window_minutes"])
            else { continue }
            let window = RateLimitWindow(
                usedPercent: max(0, min(100, Int(percent.rounded()))),
                resetsAt: number(entry["resets_at"]).map { Int($0) })
            // 1日 (1440分) を境に日次枠/週次枠を判定する
            if minutes >= 1440 { week = window } else { five = window }
        }
        let limits = AgentRateLimits(fiveHour: five, sevenDay: week)
        return limits.isEmpty ? nil : limits
    }

    // MARK: - rollout

    private static func rolloutPath(sessionID: String, transcriptPath: String?) -> String? {
        if let transcriptPath, !transcriptPath.isEmpty,
           FileManager.default.fileExists(atPath: transcriptPath) {
            return transcriptPath
        }
        if let recorded = thread(sessionID: sessionID)?.rolloutPath,
           FileManager.default.fileExists(atPath: recorded) {
            return recorded
        }
        return nil
    }

    /// rollout ファイルの末尾から直近の `token_count` イベントを探索する。
    /// ファイルサイズ肥大化に対応するため、末尾から段階的にウィンドウサイズを広げてシークする。
    private static func lastTokenCount(inRollout path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        var window: UInt64 = 256 * 1024
        let ceiling: UInt64 = 8 * 1024 * 1024
        while true {
            let start = size > window ? size - window : 0
            // 行の途中にシークした場合の誤判定を避けるため1バイト前から読み取りを開始する
            let from = start > 0 ? start - 1 : 0
            // 読み取り中に追記された場合も想定ウィンドウサイズのみ読み込む
            guard (try? handle.seek(toOffset: from)) != nil,
                  let data = try? handle.read(upToCount: Int(size - from))
            else { return nil }

            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            if start > 0 && !lines.isEmpty { lines.removeFirst() }

            for line in lines.reversed() {
                guard let payload = tokenCountPayload(line) else { continue }
                return payload
            }
            if start == 0 || window >= ceiling { return nil }
            // 上限で頭打ちにする。掛けてから測ると、諦める前に上限の倍を読んでしまう
            window = min(window * 4, ceiling)
        }
    }

    private static func tokenCountPayload(_ line: String) -> [String: Any]? {
        guard line.contains("token_count"),
              let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "token_count"
        else { return nil }
        return payload
    }

    // MARK: - threads 表

    private struct Thread {
        var name: String?
        var title: String?
        var firstUserMessage: String?
        var rolloutPath: String?
    }

    /// 同じフックの中で見出しと rollout の在処の両方を聞かれるので、
    /// 1プロセスに1回だけ開く
    private static var threadCache: [String: Thread?] = [:]

    private static func thread(sessionID: String) -> Thread? {
        guard !sessionID.isEmpty else { return nil }
        if let cached = threadCache[sessionID] { return cached }
        let row = readThread(sessionID: sessionID)
        threadCache[sessionID] = row
        return row
    }

    private static func readThread(sessionID: String) -> Thread? {
        guard let dbPath = stateDatabasePath() else { return nil }

        var db: OpaquePointer?
        // 読むだけで開く。codex 本体が書いている最中なので、こちらは邪魔をしない
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_close(db) }
        // 読みに行くのは codex が動いている真っ最中なので、書き込みとかち合う。
        // 一瞬待てば取れるものを名前無しで諦めないよう、少しだけ待つ
        sqlite3_busy_timeout(db, 50)

        var stmt: OpaquePointer?
        let sql = "SELECT name, title, first_user_message, rollout_path FROM threads WHERE id = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sessionID, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        func text(_ column: Int32) -> String? {
            guard let raw = sqlite3_column_text(stmt, column) else { return nil }
            let value = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        return Thread(name: text(0), title: text(1),
                      firstUserMessage: text(2), rolloutPath: text(3))
    }

    /// 台帳のファイル名には版が入る (`state_5.sqlite`)。codex が版を上げると
    /// 別のファイルになるので、名前を決め打ちせず一番新しい版を選ぶ
    private static func stateDatabasePath() -> String? {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: codexHome)) ?? []
        let versions = files.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"),
                  let version = Int(name.dropFirst("state_".count).dropLast(".sqlite".count))
            else { return nil }
            return (version, name)
        }
        guard let newest = versions.max(by: { $0.0 < $1.0 })?.1 else { return nil }
        return (codexHome as NSString).appendingPathComponent(newest)
    }

    // MARK: - 小道具

    private static func firstLine(of text: String?) -> String? {
        guard let text else { return nil }
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return truncate(trimmed, limit: 60) }
        }
        return nil
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 3)) + "..." : text
    }

    /// JSON の数は Int でも Double でも来る。どちらでも受ける
    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        return nil
    }
}
