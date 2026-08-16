import Foundation
import ProctorKit

func cmdRm(_ args: Args) throws -> Int32 {
    let result = try RemoveWorktree.run(
        id: try args.require(0, "タスクID"),
        force: args.has("-f", "--force"))
    report(result)
    return 0
}

private func report(_ result: RemoveWorktree.Result) {
    if result.recordOnly {
        print("\(Terminal.color("32", "一覧から外しました"))  "
            + "[\(result.task.id)] \(result.task.branch)")
        return
    }
    print("\(Terminal.color("32", "🧹 片付けました"))  "
        + "[\(result.task.id)] \(result.task.branch)")
    if result.branchLeftBehind {
        Terminal.note("  ブランチ \(result.task.branch) は未マージのため残しました")
    }
}

func cmdClean(_ args: Args) throws -> Int32 {
    guard let repo = GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    else { throw ProctorError("git リポジトリの中で実行してください") }

    if LedgerStore.tasks().allSatisfy({ $0.repo != repo }) {
        print("このリポジトリにタスクはありません")
        return 0
    }

    let plan = try CleanMergedWorktrees.plan(in: repo)
    if plan.isEmpty {
        print("マージ済みのタスクはありません")
        return 0
    }

    if !plan.removable.isEmpty {
        print("マージ済みなので片付けられます:")
        for (task, number) in plan.removable {
            print("  [\(task.id)] \(task.branch)  #\(number)")
        }
    }
    if !plan.dirty.isEmpty {
        print("\nコミットしていない変更があるので残します:")
        for task in plan.dirty {
            print("  [\(task.id)] \(task.branch)  消すなら proctor rm -f \(task.id)")
        }
    }
    if plan.removable.isEmpty { return 0 }

    // AI やサイドバーから呼ばれても止まらないよう、対話では聞かない。
    // 消すのは戻せない操作なので、既定は一覧を出すだけにしておく
    if !args.has("-y", "--yes") {
        print("\n実際に片付けるには --yes を付けてください")
        return 0
    }

    for (task, error) in CleanMergedWorktrees.apply(plan) {
        Terminal.note("  [\(task.id)] は片付けられませんでした: \(error)")
    }
    return 0
}
