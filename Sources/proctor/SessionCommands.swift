import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import Resources
import UseCaseSession
import UseCaseTask
import Utility

/// ユーザー対話用 CLI コマンド。UseCase を呼び出して結果を整形する。

func cmdLs(_ args: Args) throws -> Int32 {
    let all = args.has("--all")
    let repo = all ? nil : GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    if !all && repo == nil && !args.has("--json") {
        // カレントディレクトリが git リポジトリ外の場合は全件表示になる旨を通知する
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
        // 実行中サブエージェントは親タスク行の下にツリー形式で表示する
        notes: tasks.map { task in
            let subs = task.currentSubagents
            return subs.enumerated().map { index, sub in
                Terminal.subagent(sub, isLast: index == subs.count - 1)
            }
        })
    return 0
}

/// セッションのエージェント（claude / agy / codex）を起動し、会話を再開する。
/// プロセスを execvp で置き換えるため、正常時はこのプロセスには戻らない。
func cmdAttach(_ args: Args) throws -> Int32 {
    let task = try LedgerStore.find(id: try args.require(0, Localized.text("cli.arg.session_id")))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw ProctorError(Localized.text("cli.error.worktree_missing", task.worktree))
    }

    // エージェントごとのセッション再開用引数を構築する
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
    // execvp 成功時は戻らないため、到達した場合は起動失敗エラーを送出する
    throw ProctorError(Localized.text("cli.error.launch_failed", binary))
}

/// 台帳からタスクレコードを削除する。
/// 通常はプロセスの生死監視で自動消去されるが、手動での即時クリーンアップ用として提供する。
func cmdRm(_ args: Args) throws -> Int32 {
    let task = try ForgetTask.forget(id: try args.require(0, Localized.text("cli.arg.session_id")))
    // 作業ディレクトリ自体は削除されず記録のみ消去された旨を通知する
    print(Localized.text("cli.removed", task.id, task.worktree))
    return 0
}

/// カレントセッションにタイトルを設定する。セッションの特定は環境変数経由で行う。
func cmdTitle(_ args: Args) throws -> Int32 {
    // 引数なし（エラー）と空文字（タイトル削除）を区別するため先に require を通す
    _ = try args.require(0, Localized.text("cli.arg.title"))
    // クォートなしの複数単語指定も許容するため空白で結合する
    let text = args.positional.joined(separator: " ")
    let task = try NameSession.name(title: text)
    print(task.title.map { Localized.text("cli.title.set", task.id, $0) }
        ?? Localized.text("cli.title.cleared", task.id))
    return 0
}

/// サイドバーアプリ（Agent Proctor.app）を起動する
func cmdSidebar(_ args: Args) throws -> Int32 {
    guard let bundle = Paths.appBundle?.path else {
        throw ProctorError(Localized.text("cli.error.app_not_found"))
    }
    guard ProcessRunner.inherit(["open", "-a", bundle]) == 0 else {
        throw ProctorError(Localized.text("cli.error.app_launch_failed"))
    }
    return 0
}
