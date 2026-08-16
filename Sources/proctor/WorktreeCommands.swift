import Foundation
import ProctorKit

/// worktree を扱うコマンド。
/// どれも UseCase を呼んで、返ってきたものを端末向けに整えるだけにする。

func cmdNew(_ args: Args) throws -> Int32 {
    guard let repo = GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    else { throw ProctorError("git リポジトリの中で実行してください") }

    let fetch = !args.has("--no-fetch")
    if fetch { Terminal.note("origin を取得中...") }

    let result = try CreateWorktree.run(in: repo, .init(
        name: try args.require(0, "ブランチ名またはチケットキー"),
        base: args.value("--base"),
        ticket: args.value("--ticket"),
        fetch: fetch))

    for note in result.notes { Terminal.note("  \(note)") }

    if args.has("--json") {
        print(try prettyJSON(result.task))
        return 0
    }
    print("\n\(Terminal.color("32", "✅ worktree を用意しました"))  [\(result.task.id)]")
    print("  ブランチ : \(result.task.branch)  (ベース: origin/\(result.baseBranch))")
    print("  パス     : \(result.task.worktree)")
    print("\n  cd \"$(proctor open \(result.task.id))\" で移動できます")
    return 0
}

func cmdLs(_ args: Args) throws -> Int32 {
    let all = args.has("--all")
    let repo = all ? nil : GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    if !all && repo == nil && !args.has("--json") {
        // 黙って全件出すと、絞り込めているのか区別がつかない
        Terminal.note("git リポジトリの外なので、すべてのタスクを表示します")
    }
    let tasks = CollectTasks.run(repo: repo, allRepos: all)

    if args.has("--json") {
        print(try prettyJSON(tasks))
        return 0
    }
    if tasks.isEmpty {
        print("タスクはありません。proctor new <名前> で作成できます")
        return 0
    }

    Terminal.table(
        headers: ["ID", "STATUS", "BRANCH", "DIFF", "AGE"],
        rows: tasks.map { task in
            let (label, code) = Terminal.style(task.status)
            return [task.id, Terminal.color(code, label), task.branch,
                    Terminal.diff(task.diff), Terminal.age(task.createdAt)]
        })
    return 0
}

func cmdOpen(_ args: Args) throws -> Int32 {
    let task = try LedgerStore.find(id: try args.require(0, "タスクID"))
    // cd "$(proctor open x)" で使うので、無いパスを返すと
    // 意味の分かりにくい cd のエラーになる。ここで止める
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw ProctorError("worktree がありません: \(task.worktree)")
    }
    if args.has("--studio") {
        guard ProcessRunner.exists("studio") else {
            throw ProctorError("studio コマンドが見つかりません")
        }
        _ = ProcessRunner.inherit(["studio", task.worktree])
        Terminal.note("Android Studio で開きました: \(task.worktree)")
        return 0
    }
    // cd "$(proctor open x)" で使うので、パス以外は stdout に出さない
    print(task.worktree)
    return 0
}

/// worktree で claude を起動する。セッションIDが分かっていれば続きから開く。
///
/// 自分のプロセスを claude に置き換えるので、成功した場合ここから戻らない。
/// サイドバーの「開く」は新しいタブでこれを実行する。
func cmdAttach(_ args: Args) throws -> Int32 {
    let task = try LedgerStore.find(id: try args.require(0, "タスクID"))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw ProctorError("worktree がありません: \(task.worktree)")
    }

    var argv = ["claude"]
    if let session = task.sessionId { argv += ["--resume", session] }

    guard FileManager.default.changeCurrentDirectoryPath(task.worktree) else {
        throw ProctorError("worktree に移動できません: \(task.worktree)")
    }
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execvp("claude", &cargs)
    // execvp は成功すれば戻らない。ここに来たのは起動できなかったということ
    throw ProctorError("claude を起動できません")
}

func cmdDiff(_ args: Args) throws -> Int32 {
    let task = try LedgerStore.find(id: try args.require(0, "タスクID"))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw ProctorError("worktree がありません: \(task.worktree)")
    }
    let point = GitClient.mergeBase(task.worktree, base: task.base)
    guard !point.isEmpty else {
        throw ProctorError("origin/\(task.base) との分岐点が見つかりません")
    }
    var cmd = ["git", "-C", task.worktree, "diff"]
    if args.has("--stat") { cmd.append("--stat") }
    cmd.append(point)
    let code = ProcessRunner.inherit(cmd)

    // 新規ファイルは git diff に現れないので、名前だけでも見せて見落としを防ぐ
    let newFiles = GitClient.untrackedFiles(task.worktree)
    if !newFiles.isEmpty {
        print(Terminal.color("36", "\n追跡外の新規ファイルが \(newFiles.count) 件あります:"))
        for name in newFiles { print("  \(name)") }
    }
    return code
}
