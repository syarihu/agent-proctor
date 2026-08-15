import Foundation
import TaskhubKit

/// ABC-123 のようなチケットキー。name がこの形なら ticket として扱う
private let ticketPattern = "^[A-Z][A-Z0-9]+-[0-9]+$"

func cmdNew(_ args: Args) throws -> Int32 {
    guard let repo = try Config.repoRoot() else {
        throw TaskhubError("git リポジトリの中で実行してください")
    }
    let config = try Config.load(repo: repo)
    let base = args.value("--base") ?? config.baseBranch ?? "main"
    let asJSON = args.has("--json")

    let name = try args.require(0, "ブランチ名またはチケットキー")
    let isTicket = name.range(of: ticketPattern, options: .regularExpression) != nil
    let ticket = args.value("--ticket") ?? (isTicket ? name : nil)
    // "/" を含むならフルのブランチ名を指定したものとみなし、prefix を足さない
    let branch = name.contains("/") ? name : config.branchPrefix + name

    let worktree = URL(fileURLWithPath: repo)
        .appendingPathComponent(config.worktreeDir)
        .appendingPathComponent(branch.replacingOccurrences(of: "/", with: "-"))
        .standardizedFileURL.resolvingSymlinksInPath()
    if FileManager.default.fileExists(atPath: worktree.path) {
        throw TaskhubError("すでに worktree があります: \(worktree.path)")
    }

    if !args.has("--no-fetch") {
        info("origin を取得中...")
        _ = try? git(repo, "fetch", "origin", "--quiet", check: false)
    }

    try Worktree.ensureIgnored(repo: repo, relativeDir: config.worktreeDir)
    try FileManager.default.createDirectory(
        at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)

    let hasLocal = gitOK(repo, "rev-parse", "--verify", "refs/heads/\(branch)")
    let hasRemote = gitOK(repo, "rev-parse", "--verify", "refs/remotes/origin/\(branch)")
    if hasLocal {
        try git(repo, "worktree", "add", worktree.path, branch)
    } else if hasRemote {
        try git(repo, "worktree", "add", "--track", "-b", branch,
                worktree.path, "origin/\(branch)")
    } else {
        guard gitOK(repo, "rev-parse", "--verify", "refs/remotes/origin/\(base)") else {
            throw TaskhubError("ベースブランチが見つかりません: origin/\(base)")
        }
        try git(repo, "worktree", "add", "-b", branch, worktree.path, "origin/\(base)")
    }

    try Worktree.setup(repo: repo, worktree: worktree.path, config: config)

    let now = Int(Date().timeIntervalSince1970)
    let task = try Ledger.withLocked { state -> TaskRecord in
        let record = TaskRecord(
            id: try Ledger.uniqueID(base: slugify(ticket ?? name), taken: state.tasks),
            repo: repo, branch: branch, worktree: worktree.path, base: base,
            ticket: ticket, kind: "manual", status: "idle",
            createdAt: now, updatedAt: now)
        state.tasks.append(record)
        return record
    }

    if asJSON {
        print(try prettyJSON(task))
        return 0
    }
    print("\n\(color("32", "✅ worktree を用意しました"))  [\(task.id)]")
    print("  ブランチ : \(branch)  (ベース: origin/\(base))")
    print("  パス     : \(worktree.path)")
    print("\n  cd \"$(taskhub open \(task.id))\" で移動できます")
    return 0
}

func cmdLs(_ args: Args) throws -> Int32 {
    let all = args.has("--all")
    let repo = all ? nil : try Config.repoRoot(strict: false)
    if !all && repo == nil && !args.has("--json") {
        // 黙って全件出すと、絞り込めているのか区別がつかない
        info("git リポジトリの外なので、すべてのタスクを表示します")
    }
    let tasks = Collect.tasks(repo: repo, allRepos: all)

    if args.has("--json") {
        print(try prettyJSON(tasks))
        return 0
    }
    if tasks.isEmpty {
        print("タスクはありません。taskhub new <名前> で作成できます")
        return 0
    }

    let headers = ["ID", "STATUS", "BRANCH", "DIFF", "AGE"]
    let rows = tasks.map { task -> [String] in
        let (label, code) = Status.style(task.status)
        return [task.id, color(code, label), task.branch,
                Worktree.format(task.diff), humanAge(task.createdAt)]
    }
    let widths = (0..<headers.count).map { i in
        max(displayWidth(headers[i]), rows.map { displayWidth($0[i]) }.max() ?? 0)
    }
    print(color("2", headers.enumerated()
        .map { pad($0.element, widths[$0.offset]) }.joined(separator: "  ")))
    for row in rows {
        let line = row.enumerated()
            .map { pad($0.element, widths[$0.offset]) }.joined(separator: "  ")
        print(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
    }
    return 0
}

func cmdOpen(_ args: Args) throws -> Int32 {
    let task = try Ledger.find(id: try args.require(0, "タスクID"))
    // cd "$(taskhub open x)" で使うので、無いパスを返すと
    // 意味の分かりにくい cd のエラーになる。ここで止める
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw TaskhubError("worktree がありません: \(task.worktree)")
    }
    if args.has("--studio") {
        guard which("studio") else {
            throw TaskhubError("studio コマンドが見つかりません")
        }
        _ = runInherit(["studio", task.worktree])
        info("Android Studio で開きました: \(task.worktree)")
        return 0
    }
    // cd "$(taskhub open x)" で使うので、パス以外は stdout に出さない
    print(task.worktree)
    return 0
}

/// worktree で claude を起動する。セッションIDが分かっていれば続きから開く。
///
/// 自分のプロセスを claude に置き換えるので、成功した場合ここから戻らない。
/// サイドバーの「開く」は新しいタブでこれを実行する。
func cmdAttach(_ args: Args) throws -> Int32 {
    let task = try Ledger.find(id: try args.require(0, "タスクID"))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw TaskhubError("worktree がありません: \(task.worktree)")
    }

    var argv = ["claude"]
    if let session = task.sessionId { argv += ["--resume", session] }

    guard FileManager.default.changeCurrentDirectoryPath(task.worktree) else {
        throw TaskhubError("worktree に移動できません: \(task.worktree)")
    }
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execvp("claude", &cargs)
    // execvp は成功すれば戻らない。ここに来たのは起動できなかったということ
    throw TaskhubError("claude を起動できません")
}

func cmdDiff(_ args: Args) throws -> Int32 {
    let task = try Ledger.find(id: try args.require(0, "タスクID"))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw TaskhubError("worktree がありません: \(task.worktree)")
    }
    let point = Worktree.mergeBase(worktree: task.worktree, base: task.base)
    guard !point.isEmpty else {
        throw TaskhubError("origin/\(task.base) との分岐点が見つかりません")
    }
    var cmd = ["git", "-C", task.worktree, "diff"]
    if args.has("--stat") { cmd.append("--stat") }
    cmd.append(point)
    let code = runInherit(cmd)

    // 新規ファイルは git diff に現れないので、名前だけでも見せて見落としを防ぐ
    let newFiles = Worktree.untrackedFiles(worktree: task.worktree)
    if !newFiles.isEmpty {
        print(color("36", "\n追跡外の新規ファイルが \(newFiles.count) 件あります:"))
        for name in newFiles { print("  \(name)") }
    }
    return code
}
