import Foundation

/// worktree を1つ用意して台帳に載せる。
///
/// CLI の `new` はこれを呼んで結果を整形するだけ。アプリから同じことを
/// させたくなったときにも、ここを呼べば足りるようにしてある。
public enum CreateWorktree {
    public struct Request {
        /// ブランチ名の末尾、またはチケットキー (例: ABC-123)
        public var name: String
        public var base: String?
        public var ticket: String?
        public var fetch: Bool

        public init(name: String, base: String? = nil,
                    ticket: String? = nil, fetch: Bool = true) {
            self.name = name
            self.base = base
            self.ticket = ticket
            self.fetch = fetch
        }
    }

    public struct Result {
        public var task: TaskRecord
        public var baseBranch: String
        /// 途中で人に知らせたいこと (何をコピーしたかなど)
        public var notes: [String]
    }

    public static func run(in repo: String, _ request: Request) throws -> Result {
        let config = try ConfigStore.load(repo: repo)
        let base = request.base ?? config.baseBranch ?? "main"

        let ticket = request.ticket
            ?? (TaskID.isTicket(request.name) ? request.name : nil)
        // "/" を含むならフルのブランチ名を指定したものとみなし、prefix を足さない
        let branch = request.name.contains("/")
            ? request.name
            : config.branchPrefix + request.name

        let worktree = URL(fileURLWithPath: repo)
            .appendingPathComponent(config.worktreeDir)
            .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
            .standardizedFileURL.resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: worktree.path) {
            throw TaskhubError("すでに worktree があります: \(worktree.path)")
        }

        if request.fetch { GitClient.fetchOrigin(repo) }

        try ensureIgnored(repo: repo, relativeDir: config.worktreeDir)
        try FileManager.default.createDirectory(
            at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)

        if GitClient.hasLocalBranch(repo, branch) {
            try GitClient.addWorktree(repo, at: worktree.path, branch: branch, tracking: nil)
        } else if GitClient.hasRemoteBranch(repo, branch) {
            try GitClient.addWorktree(repo, at: worktree.path, branch: branch,
                                      tracking: "origin/\(branch)")
        } else {
            guard GitClient.hasRemoteBranch(repo, base) else {
                throw TaskhubError("ベースブランチが見つかりません: origin/\(base)")
            }
            try GitClient.addWorktree(repo, at: worktree.path,
                                      newBranch: branch, from: "origin/\(base)")
        }

        let notes = try carryOver(repo: repo, worktree: worktree.path, config: config)

        let now = Int(Date().timeIntervalSince1970)
        let task = try LedgerStore.withLock { ledger -> TaskRecord in
            let record = TaskRecord(
                id: try TaskID.unique(base: TaskID.slugify(ticket ?? request.name),
                                      taken: ledger.tasks),
                repo: repo, branch: branch, worktree: worktree.path, base: base,
                ticket: ticket, kind: TaskRecord.Kind.manual, status: TaskStatus.idle,
                createdAt: now, updatedAt: now)
            ledger.tasks.append(record)
            return record
        }
        return Result(task: task, baseBranch: base, notes: notes)
    }

    /// worktree の置き場が git の無視対象でなければ .git/info/exclude に足す。
    ///
    /// worktree は親リポジトリから見ると untracked なディレクトリとして現れるので、
    /// 放っておくと git status が常に汚れる。共有される .gitignore ではなく
    /// そのマシンだけで効く exclude に書く。
    static func ensureIgnored(repo: String, relativeDir: String) throws {
        let probe = relativeDir.hasSuffix("/") ? relativeDir : relativeDir + "/"
        if GitClient.isIgnored(repo, probe) { return }

        let info = try GitClient.commonDir(repo).appendingPathComponent("info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let exclude = info.appendingPathComponent("exclude")

        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        // 末尾の改行で空行を作らない。直前の行が空かどうかで区切りを足すか決めるので、
        // ここがずれると追記のたびに空行が増える
        var lines = existing.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.contains(probe) { return }

        var addition = ""
        if let last = lines.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
            addition += "\n"
        }
        addition += "# taskhub が作る worktree の置き場\n\(probe)\n"
        try (existing + addition).write(to: exclude, atomically: true, encoding: .utf8)
    }

    /// gitignore されていて worktree には引き継がれないものを持ち込む。
    static func carryOver(repo: String, worktree: String,
                          config: RepoConfig) throws -> [String] {
        var notes: [String] = []

        for name in config.copyFiles {
            let src = URL(fileURLWithPath: repo).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: worktree).appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            notes.append("\(name) をコピーしました")
        }

        guard config.copyGitExclude else { return notes }
        let src = try GitClient.commonDir(repo)
            .appendingPathComponent("info").appendingPathComponent("exclude")
        guard FileManager.default.fileExists(atPath: src.path) else { return notes }

        // worktree の gitdir は .git/worktrees/<名前> 配下にあり、info/exclude は共有されない
        let dstDir = try GitClient.gitDir(worktree).appendingPathComponent("info")
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dst = dstDir.appendingPathComponent("exclude")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        notes.append(".git/info/exclude を引き継ぎました")
        return notes
    }
}
