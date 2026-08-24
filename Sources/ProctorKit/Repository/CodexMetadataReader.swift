import Foundation
import SQLite3

/// Codex CLI (codex) のセッション情報を読み出す。
///
/// **Codex には statusline に相当する差し込み口が無い** (状態行は TUI が自前で描き、
/// 中身は設定で選ぶだけ)。つまり Claude Code のように「statusline から横流しする」
/// 手が使えず、名前・文脈の残量・レートリミットが hooks の payload に載ってこない。
///
/// 代わりに codex 自身が残している2つの記録から拾う。どちらも codex が普通に
/// 動いていれば必ず出来るもので、こちらから何かを仕込む必要はない。
///
///   - `~/.codex/state_<n>.sqlite` の `threads` 表 … 見出しと rollout の在処
///   - rollout の jsonl … `token_count` イベント (文脈量とレートリミット)
public enum CodexMetadataReader {
    /// rollout から拾える、そのセッションの今の消費量。
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
    ///
    /// 優先順は「人が付けた名前 → codex が付けた題 → 最初のプロンプト」。
    /// どれも本文が丸ごと入っていることがあるので、1行目だけを取って詰める
    public static func resolveTitle(sessionID: String) -> String? {
        guard let row = thread(sessionID: sessionID) else { return nil }
        for candidate in [row.name, row.title, row.firstUserMessage] {
            if let headline = firstLine(of: candidate) { return headline }
        }
        return nil
    }

    // MARK: - 消費量

    /// そのセッションの文脈使用率とレートリミットを rollout から読む。
    ///
    /// hooks はツールを叩くたびに飛んでくるので、**同じプロセスの中では読み直さない**。
    /// フック1回につきプロセス1つなので、これで rollout を舐めるのは1回で済む
    private static var usageCache: [String: Usage?] = [:]

    /// - Parameter transcriptPath: payload の `transcript_path`。
    ///   codex はここに rollout の場所をそのまま入れてくるので、
    ///   あるなら台帳 (sqlite) を開かずに済む
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

    /// 文脈の使用率。
    ///
    /// 見るのは `last_token_usage` (直前の1往復)。`total_token_usage` は
    /// セッションを通した積算なので、窓の大きさを軽く超えていく。
    /// **今どれだけ窓が埋まっているか**を知りたいので、直前の入力+出力を使う
    private static func contextPercent(from info: [String: Any]?) -> Int? {
        guard let info,
              let window = number(info["model_context_window"]), window > 0,
              let last = info["last_token_usage"] as? [String: Any],
              let used = number(last["total_tokens"])
        else { return nil }
        return max(0, min(100, Int((used / window * 100).rounded())))
    }

    /// レートリミット。
    ///
    /// codex は primary / secondary という並びで、どちらが5時間枠かは契約で入れ替わる
    /// (週次だけの契約もある)。位置ではなく `window_minutes` で振り分ける
    private static func rateLimits(from dict: [String: Any]?) -> AgentRateLimits? {
        guard let dict else { return nil }
        var five: RateLimitWindow?
        var week: RateLimitWindow?
        for key in ["primary", "secondary"] {
            // **どちらの枠か分からないものは捨てる。** 既定を5時間枠にすると、
            // 週次の残量を「5時間枠」と言い張ることになり、しかも
            // primary と secondary が同じ側に落ちて片方が黙って消える
            guard let entry = dict[key] as? [String: Any],
                  let percent = number(entry["used_percent"]),
                  let minutes = number(entry["window_minutes"])
            else { continue }
            let window = RateLimitWindow(
                usedPercent: max(0, min(100, Int(percent.rounded()))),
                resetsAt: number(entry["resets_at"]).map { Int($0) })
            // 1日を境にする。5時間枠は 300 分、週次は 10080 分で来る
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

    /// rollout の末尾にある最後の `token_count` を拾う。
    ///
    /// **末尾から読む。** rollout はツールの出力を丸ごと積んでいくので、
    /// 長い作業では数十MBになる。フックのたびに全部読むわけにはいかない。
    /// 1回の応答ごとに `token_count` が積まれるので、普通は末尾の窓に入っている。
    /// 入っていなければ窓を4倍に広げて数回だけ遡り、それでも無ければ諦める
    /// (無いものを探して読み切るより、その回は出さないほうが安い)。
    ///
    /// 窓は重ねて読み直すので、最後まで空振りした場合の総量は上限そのものではなく
    /// 256KB+1MB+4MB+8MB になる。**空振りは1プロセスに1回だけ**
    /// (`usageCache` が「無かった」も憶える) なので、重ならない読み方にして
    /// 込み入らせるより、ここは素直さを取っている
    private static func lastTokenCount(inRollout path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        var window: UInt64 = 256 * 1024
        let ceiling: UInt64 = 8 * 1024 * 1024
        while true {
            let start = size > window ? size - window : 0
            // **1バイト手前から読む。** 窓の頭は行の途中に落ちるので先頭は捨てるのだが、
            // ちょうど改行の直後に落ちると丸ごと読めている行を捨ててしまう。
            // 1つ手前から読めば先頭は必ず「切れた行」か空になり、迷わず捨てられる
            let from = start > 0 ? start - 1 : 0
            // **末尾まで読ませない。** rollout は codex が書いている最中で、
            // 読んでいる間にも伸びる。最後まで読む書き方だと、窓の大きさを
            // 決めた意味が無くなり、伸びたぶんだけ余計に読んでしまう
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
