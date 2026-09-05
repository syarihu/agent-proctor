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
    ///
    /// **頭から少しずつ読む。** 欲しいのは最初のプロンプト1つなのに、
    /// transcript はセッションが進むと数MBまで育つ。丸ごと文字列にして
    /// 全行に分けると、その1行のために台帳の更新のたびに数MBを触ることになる。
    /// 足りなければ窓を倍にして読み直し、それでも見つからなければ諦める
    /// (最初のプロンプトがそこまで後ろに居ることはない)。
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
            // 窓を使い切っているなら、最後の行は途中で切れている見込み。
            // 半端な行を JSON として解こうとしても外れるだけなので捨てる
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
            // 読み切っていれば、この先にも無い
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

    /// Antigravity のサブエージェントである場合、親の conversationID と素性（Role/TypeName/Prompt）を解決する。
    ///
    /// Antigravity はサブエージェントごとに独立した conversationId を発行し、フックもその ID で届く。
    /// 親の transcript.jsonl に記録された invoke_subagent の生成ログを辿ることで、
    /// 親子関係を結び、独立タスクではなく親セッションの配下にぶら下げられるようにする。
    ///
    /// 親の候補は**呼ぶ側が渡す**。ここから台帳を読みに行かないのは、
    /// 台帳の出入り口を1つに保つため (Repository どうしで呼び合わない)。
    /// 渡すのは台帳に載っている Antigravity セッションの sessionId で、
    /// 普段は1〜2件しかない。**agy を1枚しか開いていなければ、親自身の
    /// イベントでは候補が0件になり I/O は起きない**。2枚以上開いていれば
    /// 他方のログを 64KB 読んで空振りする分は掛かる。
    ///
    /// **見つからないことは普通にある。** 親が喋り続けると生成の記録が
    /// 読み取り窓 (末尾64KB) から流れ出てしまう。一度結び付いた親子を
    /// 離さないための覚えは呼ぶ側が持つこと (台帳の subagentRuns)。
    ///
    /// - Parameter activeParentIDs: 親になりうるセッションの conversationId。
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
            // **末尾まで読ませない。** transcript は親が書いている最中で、読んでいる
            // 間にも伸びる。readDataToEndOfFile だと窓の大きさを決めた意味が無くなる
            // (CodexMetadataReader.lastTokenCount と同じ理由・同じ読み方)
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: Int(fileSize - offset))
            else { continue }
            // **切り出した先頭がマルチバイト文字の途中になることがある。**
            // String(data:encoding:) はそこで nil を返すので、親のログが
            // 手元にあるのに読まずに捨ててしまう (日本語のログでは頻繁に起きる)。
            // 壊れたバイトは置換文字にして読み進める
            let chunk = String(decoding: data, as: UTF8.self)
            guard chunk.contains(conversationID) else { continue }

            if let info = parseSubagentInfo(from: chunk, childID: conversationID, parentID: parentID) {
                return info
            }
        }
        return nil
    }

    /// **文字列で当たりを付けてから解く。**
    ///
    /// 64KB には数百行が入っている。素直に全部 JSON にすると、欲しい1行の
    /// ために毎回それだけ払うことになる。目印は地の文にそのまま出るので、
    /// 先に絞り込めば解くのは1〜2行で済む。
    private static func parseSubagentInfo(from chunk: String, childID: String, parentID: String) -> SubagentInfo? {
        let lines = chunk.components(separatedBy: .newlines)

        for index in lines.indices.reversed() {
            guard lines[index].contains(childID),
                  lines[index].contains("Created the following subagents"),
                  let step = decodeStep(lines[index]),
                  let contentStr = step["content"] as? String
            else { continue }

            // **文言だけで決めない。** 親が自分のログを grep や cat で覗くと、
            // そのコマンド出力にも同じ文言と子の ID がそのまま乗る。
            // それを生成の記録と取り違えると、遡って見つかる invoke_subagent が
            // 別の呼び出しになり、他の子の素性を配ってしまう。
            // 本物は文言の直後が必ず JSON の始まりなので、そこで見分ける
            if let block = createdSubagentsBlock(in: contentStr), block.contains(childID) {
                // 一度に何体も起こせるので、**この子が何番目に生まれたか**を数える。
                // 頼んだ側の配列 (Subagents) には conversationId が入っておらず、
                // 結び付ける手掛かりは並び順しか無い
                let position = createdConversationIDs(in: block).firstIndex(of: childID)

                // 素性 (Role/Prompt) は頼んだ側にしか無く、生成の記録より
                // 必ず前に来る。だから見つけた行から手前へ遡る
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
                        // 並び順が読めなければ、1体しか頼んでいないときだけ当てにする。
                        // 何体も居るのに先頭を配ると、2体目以降に1体目の素性が付く
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

    /// 生成の記録の**本体だけ**を切り出す。見つからなければ nil。
    ///
    /// 本物は文言の直後が JSON の始まりになっている。偽物の弾き方は呼ぶ側に書いた。
    ///
    /// 切り出すのは、続く `createdConversationIDs` に**文言より前を見せない**ため。
    /// 前の方に別の `"conversationId"` があると、数えた位置が丸ごとずれる。
    private static func createdSubagentsBlock(in content: String) -> Substring? {
        guard let phrase = content.range(of: "Created the following subagents:") else {
            return nil
        }
        let block = content[phrase.upperBound...]
        let head = block.drop { $0.isWhitespace }
        guard head.first == "{" || head.first == "[" else { return nil }
        return block
    }

    /// 生成の記録に並んだ conversationId を**出てきた順に**拾う。
    ///
    /// 頼んだ側の Subagents 配列と順番が対応しているので、位置で結び付けるのに使う。
    /// JSON の断片が地の文に埋まった形なので、鍵の名前を目印に拾う。
    private static func createdConversationIDs(in content: Substring) -> [String] {
        let marker = "\"conversationId\""
        var ids: [String] = []
        var rest = content
        while let markerRange = rest.range(of: marker) {
            rest = rest[markerRange.upperBound...]
            // "conversationId" : "…" の値だけを取る。空白とコロンは読み飛ばす。
            // **値が文字列でなければ諦める** (null など)。次に出てきた引用符を
            // 拾ってしまうと、無関係な文字列を ID として並べることになる
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

    /// 承認待ちのステップに付く status。**Antigravity の内部 enum の番号**
    /// (`CORTEX_STEP_STATUS_WAITING`)。
    ///
    /// **宣言順と番号が一致しない。** 実物は PENDING=1 RUNNING=2 DONE=3 …
    /// GENERATING=8 WAITING=9 と飛ぶので、名前の並びから数えると外れる。
    /// 引き直すときは agy のバイナリに埋まっている protobuf の descriptor を解く
    /// (`\x12<長さ>\x0a<長さ>CORTEX_STEP_STATUS_<名前>\x10<番号>` を拾う)。
    ///
    /// 公開された口ではないので、向こうが振り直せば黙って効かなくなる。
    /// 気づけるのは「許可待ちなのに ⏳ が出ない」という形だけ
    private static let waitingStepStatus = 9

    /// 会話の記録が積まれる場所。
    ///
    /// **見張る側に渡すためだけに公開している。** 置き場を知っているのは
    /// ここ (Repository) だけにしておきたいので、パスを組み立てさせない。
    /// **中を並べてはいけない** (理由は下の `isAwaitingApproval`)
    public static var conversationsDirectory: String {
        (cliHome as NSString).appendingPathComponent("conversations")
    }

    /// その会話が、いま人の承認を待って止まっているか。
    ///
    /// **Antigravity には「訊いている」を知らせるフックが無い。** 送ってくるのは
    /// PreToolUse / PostToolUse / PreInvocation / PostInvocation / Stop の5つだけで、
    /// しかも PreToolUse は許可の判定より**前**に走る (あれの stdout の `decision` が
    /// 人に訊くかどうかを決める入力そのもの)。断られたときもフックは飛ばない。
    /// つまり挙げる合図も降ろす合図もフックからは来ないので、
    /// あちらが書いている会話の記録を直接見るしかない。
    ///
    /// **置き場を走査してはいけない。** タイトルの自動生成のような裏方が、
    /// 2ステップだけの短命な会話を次々作る。見に行くのは台帳に載っている
    /// conversationId だけにすること。
    ///
    /// 末尾のステップではなく status で引くのは、裏で走っている仕事が
    /// 後ろに積まれても手の挙がっているステップを見落とさないため
    /// (`idx_steps_status` があるので、どちらでも値段は変わらない)。
    ///
    /// **読めなかったときは nil。「待っていない」と一緒にしてはいけない。**
    ///
    /// この DB は WAL なので、読むだけでも `-shm` が要る。ところが agy は
    /// **待たせている最中にも記録を畳んで閉じる**ことがあり、その一瞬だけ
    /// `-shm` も `-wal` も消える。読み取り専用では作れないので、開くこと自体が失敗する。
    ///
    /// ここで false を返すと、**挙がっていた手が勝手に降りる** ——
    /// 権限確認が出たままなのに ⏳ が消え、次に確かめるまで戻らない。
    /// 実際にそれが起きたので、答えを3つに分けてある。
    /// 読めた結果だけが答えで、読めなかったのは**何も言っていない**。
    ///
    /// (`immutable=1` を付ければ `-shm` 無しでも開けるが、あれは `-wal` を
    /// まるごと無視する。書かれたばかりの手が `-wal` の中に居ると見落とすので、
    /// 「読めない」を「待っていない」に化けさせる元の間違いをやり直すことになる。)
    ///
    /// - Returns: 待っているなら true、待っていないなら false、**分からなければ nil**
    public static func isAwaitingApproval(conversationID: String) -> Bool? {
        guard !conversationID.isEmpty else { return nil }
        let dbPath = (conversationsDirectory as NSString)
            .appendingPathComponent("\(conversationID).db")

        // **開けなくても取っ手は返る。** 閉じずに戻ると、開けない会話を
        // 何度も叩くこの道では取っ手が積み上がる。
        // だから defer を張ってから開けたかどうかを見る
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
        // 読んでいる最中に畳まれた・壊れていた。**言い切らない**
        default: return nil
        }
    }
}
