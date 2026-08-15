import Foundation
import TaskhubKit

/// worktree とブランチを消す。破壊的な操作なので、確かめられなければ止める。
///
/// - Parameter force: 未コミット・未マージの確認を飛ばして強制的に消す
private func removeTask(id: String, force: Bool) throws {
    var removed: TaskRecord?
    var leftBehind = false
    var wasSession = false

    try Ledger.withLocked { state in
        let task = try Ledger.find(id: id, in: state.tasks)
        removed = task

        // 対話セッションの記録は taskhub が作ったものではない。
        // worktree はリポジトリ本体そのものなので、消すのは記録だけにする
        if task.isSession {
            wasSession = true
            state.tasks.removeAll { $0.id == task.id }
            return
        }

        let exists = FileManager.default.fileExists(atPath: task.worktree)
        if exists && !force {
            // git が失敗したときに「変更なし」と読んでしまうと、
            // 守るための確認が素通りする。成否を見て、確かめられなければ止める
            let (statusOK, dirty) = gitTry(task.worktree, "status", "--porcelain")
            guard statusOK else {
                throw TaskhubError(
                    "worktree の状態を確認できませんでした。削除する場合は -f を付けてください")
            }
            guard dirty.isEmpty else {
                throw TaskhubError(
                    "コミットしていない変更があります。削除する場合は -f を付けてください")
            }

            let (aheadOK, ahead) = gitTry(task.worktree, "rev-list", "--count",
                                          "origin/\(task.base)..HEAD")
            guard aheadOK else {
                throw TaskhubError(
                    "origin/\(task.base) と比べられませんでした。削除する場合は -f を付けてください")
            }
            if !ahead.isEmpty && ahead != "0" {
                throw TaskhubError(
                    "origin/\(task.base) に入っていないコミットが \(ahead) 件あります。"
                    + "削除する場合は -f を付けてください")
            }
        }

        if exists {
            var remove = ["worktree", "remove", task.worktree]
            if force { remove.append("--force") }
            try run(["git", "-C", task.repo] + remove)
        } else {
            _ = try? git(task.repo, "worktree", "prune", check: false)
        }

        if gitOK(task.repo, "rev-parse", "--verify", "refs/heads/\(task.branch)") {
            // git のエラーをそのまま垂れ流すと「片付けました」と矛盾して見えるので、
            // 失敗は自前の言葉で伝える
            if !gitOK(task.repo, "branch", force ? "-D" : "-d", task.branch) {
                leftBehind = true
            }
        }

        state.tasks.removeAll { $0.id == task.id }
    }

    guard let task = removed else { return }
    if wasSession {
        print("\(color("32", "一覧から外しました"))  [\(task.id)] \(task.branch)")
        return
    }
    print("\(color("32", "🧹 片付けました"))  [\(task.id)] \(task.branch)")
    if leftBehind {
        info("  ブランチ \(task.branch) は未マージのため残しました")
    }
}

func cmdRm(_ args: Args) throws -> Int32 {
    try removeTask(id: try args.require(0, "タスクID"), force: args.has("-f", "--force"))
    return 0
}

/// gh から見たマージ済み PR のブランチ名 → PR 番号。gh が使えなければ nil。
private func mergedBranches(repo: String) -> [String: Int]? {
    guard which("gh") else { return nil }
    let (ok, output) = ghPRList(repo: repo)
    guard ok, let data = output.data(using: .utf8),
          let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return nil }

    var merged: [String: Int] = [:]
    for pr in list {
        if let branch = pr["headRefName"] as? String, let number = pr["number"] as? Int {
            merged[branch] = number
        }
    }
    return merged
}

private func ghPRList(repo: String) -> (ok: Bool, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["gh", "pr", "list", "--state", "merged", "--limit", "100",
                         "--json", "number,headRefName"]
    process.currentDirectoryURL = URL(fileURLWithPath: repo)
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return (false, "") }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
}

func cmdClean(_ args: Args) throws -> Int32 {
    guard let repo = try Config.repoRoot() else {
        throw TaskhubError("git リポジトリの中で実行してください")
    }
    let tasks = Ledger.loadTasks().filter { $0.repo == repo }
    if tasks.isEmpty {
        print("このリポジトリにタスクはありません")
        return 0
    }

    guard let merged = mergedBranches(repo: repo) else {
        throw TaskhubError(
            "gh からマージ済み PR を取得できませんでした。gh auth login を確認してください")
    }

    let targets = tasks.filter { merged[$0.branch] != nil }
    if targets.isEmpty {
        print("マージ済みのタスクはありません")
        return 0
    }

    // マージ済みでも、その後に手を入れて未コミットのまま置いてあることがある。
    // コミットされていない変更と追跡外のファイルは消すと戻せないので、
    // まとめての片付けからは外す
    var removable: [TaskRecord] = []
    var dirty: [TaskRecord] = []
    for task in targets {
        let exists = FileManager.default.fileExists(atPath: task.worktree)
        let changes = exists
            ? ((try? git(task.worktree, "status", "--porcelain",
                         check: false, quiet: true)) ?? "")
            : ""
        if exists && !changes.isEmpty { dirty.append(task) } else { removable.append(task) }
    }

    if !removable.isEmpty {
        print("マージ済みなので片付けられます:")
        for task in removable {
            print("  [\(task.id)] \(task.branch)  #\(merged[task.branch] ?? 0)")
        }
    }
    if !dirty.isEmpty {
        print("\nコミットしていない変更があるので残します:")
        for task in dirty {
            print("  [\(task.id)] \(task.branch)  消すなら taskhub rm -f \(task.id)")
        }
    }
    if removable.isEmpty { return 0 }

    // AI やサイドバーから呼ばれても止まらないよう、対話では聞かない。
    // 消すのは戻せない操作なので、既定は一覧を出すだけにしておく
    if !args.has("-y", "--yes") {
        print("\n実際に片付けるには --yes を付けてください")
        return 0
    }

    for task in removable {
        // マージ済みでもローカルには未 push のマージコミット等が残りうるので強制で消す。
        // 1件失敗しても残りは片付ける
        do {
            try removeTask(id: task.id, force: true)
        } catch {
            info("  [\(task.id)] は片付けられませんでした: \(error)")
        }
    }
    return 0
}
