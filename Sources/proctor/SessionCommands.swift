import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import Resources
import UseCaseSession
import UseCaseTask
import Utility

/// 人が使うコマンド。UseCase を呼んで、結果を端末向けに整えるだけにする。

func cmdLs(_ args: Args) throws -> Int32 {
    let all = args.has("--all")
    let repo = all ? nil : GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    if !all && repo == nil && !args.has("--json") {
        // 黙って全件出すと、絞り込めているのか区別がつかない
        Terminal.note(Localized.text("cli.outside_repo"))
    }
    let tasks = CollectTasks.collect(repo: repo, allRepos: all)

    if args.has("--json") {
        print(try prettyJSON(tasks))
        return 0
    }
    if tasks.isEmpty {
        print(Localized.text("common.no_agents"))
        return 0
    }

    Terminal.table(
        headers: ["ID", "STATUS", "BRANCH", "DIFF", "AGE"],
        rows: tasks.map { task in
            let (label, code) = Terminal.style(task.displayStatus)
            return [task.id, Terminal.color(code, label), task.branch,
                    Terminal.diff(task.diff), Terminal.age(task.createdAt)]
        },
        // 走っているサブエージェントはその行の下にぶら下げる。
        // 列に入れると数しか置けず、何をさせているかが出せない
        notes: tasks.map { task in
            let subs = task.currentSubagents
            return subs.enumerated().map { index, sub in
                Terminal.subagent(sub, isLast: index == subs.count - 1)
            }
        })
    return 0
}

/// そのセッションのエージェント (claude / agy / codex) を開く。会話の続きから始める。
///
/// 自分のプロセスをエージェントに置き換えるので、成功した場合ここから戻らない。
/// サイドバーの行をクリックしたとき、タブが既に閉じていればこれが新しいタブで走る。
func cmdAttach(_ args: Args) throws -> Int32 {
    let task = try LedgerStore.find(id: try args.require(0, Localized.text("cli.arg.session_id")))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw ProctorError(Localized.text("cli.error.worktree_missing", task.worktree))
    }

    // 続きから開く言い方はエージェントごとに違う。
    // codex だけは副コマンド (`codex resume <ID>`) で、旗ではない
    let binary: String
    var resumption: [String] = []
    switch task.agent {
    case AgentKind.antigravity:
        binary = "agy"
        if let session = task.sessionId { resumption = ["--conversation", session] }
    case AgentKind.codex:
        binary = "codex"
        if let session = task.sessionId { resumption = ["resume", session] }
    default:
        binary = "claude"
        if let session = task.sessionId { resumption = ["--resume", session] }
    }
    let argv = [binary] + resumption

    guard FileManager.default.changeCurrentDirectoryPath(task.worktree) else {
        throw ProctorError(Localized.text("cli.error.worktree_unreachable", task.worktree))
    }
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execvp(binary, &cargs)
    // execvp は成功すれば戻らない。ここに来たのは起動できなかったということ
    throw ProctorError(Localized.text("cli.error.launch_failed", binary))
}

/// 台帳から1件外す。
///
/// 掃除はプロセスの生死で自動的に回るので、普段は要らない。
/// プロセスを追えないまま残った古い記録 (この仕組みより前のもの・Claude Code 以外) を
/// 期限切れを待たずに片付けるための逃げ道として置いてある。
func cmdRm(_ args: Args) throws -> Int32 {
    let task = try ForgetTask.forget(id: try args.require(0, Localized.text("cli.arg.session_id")))
    // 消したのは記録だけ。作業していた場所は残っていることを断っておく
    print(Localized.text("cli.removed", task.id, task.worktree))
    return 0
}

/// いま自分が動いているセッションに名前を付ける。
///
/// **どのセッションかを引数で受けない。** 誰の行かは環境変数から特定する
/// (理由は `NameSession.locate`)。
func cmdTitle(_ args: Args) throws -> Int32 {
    // 先に `require` を通すのは、**引数なしと空文字を分ける**ため。
    // 前者は打ち間違いなので止め、後者は「名前を外す」という指示として通す
    _ = try args.require(0, Localized.text("cli.arg.title"))
    // 引用符を忘れた呼び方 (`proctor title 台帳を直す`) でも通るように繋ぐ
    let text = args.positional.joined(separator: " ")
    let task = try NameSession.run(title: text)
    print(task.title.map { Localized.text("cli.title.set", task.id, $0) }
        ?? Localized.text("cli.title.cleared", task.id))
    return 0
}

/// iTerm2 の左側に吸着するサイドバー (Agent Proctor.app) を起動する。
///
/// 描画も iTerm2 との連携もアプリ側が持つので、ここは起動して渡すだけ。
/// どこに入っているかは置き方で変わるので、探すのは Paths に任せる。
func cmdSidebar(_ args: Args) throws -> Int32 {
    guard let bundle = Paths.appBundle?.path else {
        throw ProctorError(Localized.text("cli.error.app_not_found"))
    }
    guard ProcessRunner.inherit(["open", "-a", bundle]) == 0 else {
        throw ProctorError(Localized.text("cli.error.app_launch_failed"))
    }
    return 0
}
