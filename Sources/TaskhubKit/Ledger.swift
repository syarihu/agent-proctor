import Foundation

public struct StateFile: Codable, Equatable {
    public var version: Int
    public var tasks: [TaskRecord]

    public init(version: Int = 1, tasks: [TaskRecord] = []) {
        self.version = version
        self.tasks = tasks
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tasks = try box.decodeIfPresent([TaskRecord].self, forKey: .tasks) ?? []
    }
}

public enum Ledger {
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

    public static func read() -> StateFile {
        guard let data = try? Data(contentsOf: Paths.stateFile) else {
            return StateFile()
        }
        do {
            return try JSONDecoder().decode(StateFile.self, from: data)
        } catch {
            // 壊れていても操作を止めない。作り直せる程度の情報しか持たせていない。
            // ただし次の書き込みで消えてしまうので、原因を追えるよう退避しておく
            try? FileManager.default.removeItem(at: Paths.brokenStateFile)
            try? FileManager.default.moveItem(at: Paths.stateFile, to: Paths.brokenStateFile)
            return StateFile()
        }
    }

    public static func write(_ state: StateFile) throws {
        try FileManager.default.createDirectory(
            at: Paths.stateDir, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        let tmp = Paths.stateDir.appendingPathComponent("state.json.tmp")
        try (data + Data("\n".utf8)).write(to: tmp)
        // 置き換えは rename(2) で原子的に行う。読み手が半端な JSON を見ることはない。
        // FileManager.replaceItemAt は置換先が無いと失敗するのでこちらを使う
        // (台帳は初回の書き込み時にはまだ存在しない)
        guard rename(tmp.path, Paths.stateFile.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw TaskhubError("台帳を書き込めません: \(Paths.stateFile.path)")
        }
    }

    /// 読み → 変更 → 書き を排他ロックで囲む。
    ///
    /// hooks からも並行して書かれるため、読んでから書くまでを1つのロックに入れる。
    ///
    /// 中身が変わらなかったときは書かない。台帳の更新時刻はサイドバーが変化を知る
    /// 合図になっているので、無変更で触るとその都度数え直しが走ってしまう。
    /// hooks は PostToolUse のように何度も呼ばれ、多くは何も変えずに終わる。
    ///
    /// 同一プロセスから入れ子で呼ぶとデッドロックする (flock は同じプロセスの
    /// 別の fd 同士でもブロックする)。ロックの中でさらにこれを呼ぶ関数を作らないこと。
    @discardableResult
    public static func withLocked<T>(_ body: (inout StateFile) throws -> T) throws -> T {
        try FileManager.default.createDirectory(
            at: Paths.stateDir, withIntermediateDirectories: true)

        let fd = open(Paths.lockFile.path, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw TaskhubError("ロックを開けません: \(Paths.lockFile.path)")
        }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else {
            throw TaskhubError("ロックを取得できません: \(Paths.lockFile.path)")
        }

        var state = read()
        let before = try? canonicalEncoder.encode(state)
        let result = try body(&state)
        let after = try? canonicalEncoder.encode(state)
        if before != after {
            try write(state)
        }
        return result
    }

    public static func loadTasks() -> [TaskRecord] { read().tasks }

    /// ID が完全に一致するタスク。無ければ nil。
    ///
    /// 見つからないことが普通にありうる呼び出し元 (サイドバーなど) はこちらを使う。
    public static func task(id: String, in tasks: [TaskRecord]? = nil) -> TaskRecord? {
        (tasks ?? loadTasks()).first { $0.id == id }
    }

    /// 人が打った ID を引く。前方一致でも引けるが、曖昧なら候補を出して止める。
    public static func find(id: String, in tasks: [TaskRecord]? = nil) throws -> TaskRecord {
        let all = tasks ?? loadTasks()
        if let exact = all.first(where: { $0.id == id }) { return exact }
        let hits = all.filter { $0.id.hasPrefix(id) }
        if hits.count == 1 { return hits[0] }
        if hits.count > 1 {
            throw TaskhubError("ID が曖昧です: " + hits.map(\.id).joined(separator: ", "))
        }
        throw TaskhubError("タスクが見つかりません: \(id)")
    }

    /// 指定したタスクを台帳から外す。worktree には触らない。
    ///
    /// タブが閉じられたのに記録が残っている場合の後始末に使う。
    /// SessionEnd は Claude 本体の終了に巻き込まれて届かないことがあるため、
    /// それを外から片付けるための入り口。
    public static func drop(ids: [String]) throws {
        let targets = Set(ids)
        guard !targets.isEmpty else { return }
        try withLocked { state in
            state.tasks.removeAll { targets.contains($0.id) }
        }
    }

    public static func uniqueID(base: String, taken tasks: [TaskRecord]) throws -> String {
        let used = Set(tasks.map(\.id))
        if !used.contains(base) { return base }
        for n in 2..<100 {
            let candidate = "\(base)-\(n)"
            if !used.contains(candidate) { return candidate }
        }
        throw TaskhubError("ID を採番できません")
    }
}
