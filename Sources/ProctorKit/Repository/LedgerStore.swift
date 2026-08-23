import Foundation

public struct LedgerFile: Codable, Equatable {
    public var version: Int
    public var tasks: [TaskRecord]
    /// エージェントごとの最新レートリミット情報 ("claude", "agy" など)。
    /// セッションが 0 件になっても保持し続け、常時表示に使う
    public var agentRateLimits: [String: AgentRateLimits]

    public init(version: Int = 1, tasks: [TaskRecord] = [],
                agentRateLimits: [String: AgentRateLimits] = [:]) {
        self.version = version
        self.tasks = tasks
        self.agentRateLimits = agentRateLimits
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tasks = try box.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
        agentRateLimits = try box.decodeIfPresent([String: AgentRateLimits].self, forKey: .agentRateLimits) ?? [:]
    }
}

/// 台帳そのもの。読み書きと排他を引き受ける。
///
/// hooks・CLI・アプリが同時に触るので、ここが唯一の出入り口になる。
public enum LedgerStore {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    /// 変化したかどうかの判定にだけ使う正規形。キーの順を固定して比べる
    private static let canonicalEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public static func read() -> LedgerFile {
        guard let data = try? Data(contentsOf: Paths.stateFile) else {
            return LedgerFile()
        }
        do {
            return try JSONDecoder().decode(LedgerFile.self, from: data)
        } catch {
            // 壊れていても操作を止めない。作り直せる程度の情報しか持たせていない。
            // ただし次の書き込みで消えてしまうので、原因を追えるよう退避しておく
            try? FileManager.default.removeItem(at: Paths.brokenStateFile)
            try? FileManager.default.moveItem(at: Paths.stateFile, to: Paths.brokenStateFile)
            return LedgerFile()
        }
    }

    public static func write(_ ledger: LedgerFile) throws {
        try FileManager.default.createDirectory(
            at: Paths.stateDir, withIntermediateDirectories: true)
        let data = try encoder.encode(ledger)
        let tmp = Paths.stateDir.appendingPathComponent("state.json.tmp")
        try (data + Data("\n".utf8)).write(to: tmp)
        // 置き換えは rename(2) で原子的に行う。読み手が半端な JSON を見ることはない。
        // FileManager.replaceItemAt は置換先が無いと失敗するのでこちらを使う
        // (台帳は初回の書き込み時にはまだ存在しない)
        guard rename(tmp.path, Paths.stateFile.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw ProctorError(Localized.text("error.ledger.write_failed", Paths.stateFile.path))
        }
    }

    /// 読み → 変更 → 書き を排他ロックで囲む。
    ///
    /// hooks からも並行して書かれるため、読んでから書くまでを1つのロックに入れる。
    ///
    /// 中身が変わらなかったときは書かない。台帳の更新時刻はサイドバーが変化を知る
    /// 合図になっているので、無変更で触るとその都度 git を起動して数え直してしまう。
    /// hooks は PostToolUse のように何度も呼ばれ、多くは何も変えずに終わる。
    ///
    /// 同一プロセスから入れ子で呼ぶとデッドロックする (flock は同じプロセスの
    /// 別の fd 同士でもブロックする)。ロックの中でさらにこれを呼ぶ関数を作らないこと。
    @discardableResult
    public static func withLock<T>(_ body: (inout LedgerFile) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: Paths.stateDir, withIntermediateDirectories: true)

        let fd = open(Paths.lockFile.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw ProctorError(Localized.text("error.ledger.lock_open_failed", Paths.lockFile.path))
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw ProctorError(Localized.text("error.ledger.lock_failed", Paths.lockFile.path))
        }

        var ledger = read()
        let before = try? canonicalEncoder.encode(ledger)
        let result = try body(&ledger)
        let after = try? canonicalEncoder.encode(ledger)
        if before != after {
            try write(ledger)
        }
        return result
    }

    public static func tasks() -> [TaskRecord] { read().tasks }

    /// エージェントごとの最新レートリミット情報を返す
    public static func agentRateLimits() -> [String: AgentRateLimits] { read().agentRateLimits }

    /// 台帳が最後に変わった時刻。表示側が「数え直すべきか」を判断するのに使う
    public static func lastModified() -> Date? {
        try? FileManager.default
            .attributesOfItem(atPath: Paths.stateFile.path)[.modificationDate] as? Date
    }

    /// ID が完全に一致するタスク。無ければ nil。
    ///
    /// 見つからないことが普通にありうる呼び出し元 (サイドバーなど) はこちらを使う。
    public static func task(id: String, in tasks: [TaskRecord]? = nil) -> TaskRecord? {
        (tasks ?? self.tasks()).first { $0.id == id }
    }

    /// 人が打った ID を引く。前方一致でも引けるが、曖昧なら候補を出して止める。
    public static func find(id: String, in tasks: [TaskRecord]? = nil) throws -> TaskRecord {
        let all = tasks ?? self.tasks()
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let hits = all.filter { $0.id.hasPrefix(id) }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            throw ProctorError(Localized.text("error.ledger.ambiguous_id",
                                              hits.map(\.id).joined(separator: ", ")))
        }
        throw ProctorError(Localized.text("error.ledger.not_found", id))
    }

    /// 指定したタスクを台帳から外す。worktree には触らない。
    public static func drop(ids: [String]) throws {
        let targets = Set(ids)
        guard !targets.isEmpty else { return }
        try withLock { ledger in
            ledger.tasks.removeAll { targets.contains($0.id) }
        }
    }
}
