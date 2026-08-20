import Foundation
import ProctorKit

/// 人が使うコマンド。UseCase を呼んで、結果を端末向けに整えるだけにする。

func cmdLs(_ args: Args) throws -> Int32 {
    let all = args.has("--all")
    let repo = all ? nil : GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    if !all && repo == nil && !args.has("--json") {
        // 黙って全件出すと、絞り込めているのか区別がつかない
        Terminal.note("git リポジトリの外なので、すべてのセッションを表示します")
    }
    let tasks = CollectTasks.run(repo: repo, allRepos: all)

    if args.has("--json") {
        print(try prettyJSON(tasks))
        return 0
    }
    if tasks.isEmpty {
        print("動いているエージェントはいません")
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

/// そのセッションのエージェント (claude または agy) を開く。会話の続きから始める。
///
/// 自分のプロセスをエージェントに置き換えるので、成功した場合ここから戻らない。
/// サイドバーの行をクリックしたとき、タブが既に閉じていればこれが新しいタブで走る。
func cmdAttach(_ args: Args) throws -> Int32 {
    let task = try LedgerStore.find(id: try args.require(0, "セッションID"))
    guard FileManager.default.fileExists(atPath: task.worktree) else {
        throw ProctorError("作業していた場所がありません: \(task.worktree)")
    }

    let isAgy = task.agent == "agy"
    let binary = isAgy ? "agy" : "claude"

    var argv = [binary]
    if let session = task.sessionId {
        if isAgy {
            argv += ["--conversation", session]
        } else {
            argv += ["--resume", session]
        }
    }

    guard FileManager.default.changeCurrentDirectoryPath(task.worktree) else {
        throw ProctorError("作業していた場所に移動できません: \(task.worktree)")
    }
    var cargs: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
    cargs.append(nil)
    execvp(binary, &cargs)
    // execvp は成功すれば戻らない。ここに来たのは起動できなかったということ
    throw ProctorError("\(binary) を起動できません")
}

/// 台帳から1件外す。
///
/// 掃除はプロセスの生死で自動的に回るので、普段は要らない。
/// プロセスを追えないまま残った古い記録 (この仕組みより前のもの・Claude Code 以外) を
/// 期限切れを待たずに片付けるための逃げ道として置いてある。
func cmdRm(_ args: Args) throws -> Int32 {
    let task = try ForgetTask.run(id: try args.require(0, "セッションID"))
    // 消したのは記録だけ。作業していた場所は残っていることを断っておく
    print("台帳から外しました: \(task.id) (\(task.worktree) はそのまま)")
    return 0
}

/// iTerm2 の左側に吸着するサイドバー (Agent Proctor.app) を起動する。
///
/// 描画も iTerm2 との連携もアプリ側が持つので、ここは起動して渡すだけ。
func cmdSidebar(_ args: Args) throws -> Int32 {
    let bundle = "/Applications/Agent Proctor.app"
    guard FileManager.default.fileExists(atPath: bundle) else {
        throw ProctorError(
            "Agent Proctor.app が見つかりません。scripts/install.sh でインストールしてください")
    }
    guard ProcessRunner.inherit(["open", "-a", bundle]) == 0 else {
        throw ProctorError("Agent Proctor.app を起動できませんでした")
    }
    return 0
}
