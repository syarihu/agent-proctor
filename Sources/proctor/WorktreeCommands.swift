import Foundation
import Model
import RepositoryGit
import RepositoryLedger
import Resources
import UseCaseWorktree
import Utility

/// worktree の一覧を表示する。セッションの有無に関わらず作業ディレクトリ単位で状態や差分を出力する。
func cmdWorktree(_ args: Args) throws -> Int32 {
    let sub = args.positional.first ?? "ls"
    guard sub == "ls" else {
        throw ProctorError(Localized.text("cli.error.unknown_subcommand", sub))
    }

    let all = args.has("--all")
    let repo = all ? nil : GitClient.mainWorktree(from: EnvironmentSource.currentDirectory())
    if !all && repo == nil && !args.has("--json") {
        Terminal.note(Localized.text("cli.outside_repo.worktrees"))
    }
    let repos = CollectWorktrees.collect(repo: repo, allRepos: all || repo == nil)

    if args.has("--json") {
        print(try prettyJSON(repos))
        return 0
    }
    if repos.isEmpty {
        print(Localized.text("common.no_worktrees"))
        return 0
    }

    for (index, group) in repos.enumerated() {
        if index > 0 { print("") }
        print(Terminal.color("1", group.repoName))
        Terminal.table(
            headers: ["WORKTREE", "BRANCH", "STATE", "DIFF", "IDLE"],
            rows: group.worktrees.map { worktree in
                let (label, code) = Terminal.worktreeState(worktree)
                return [worktree.name,
                        worktree.branch ?? "-",
                        Terminal.color(code, label),
                        Terminal.diff(worktree.diff),
                        // コミットが存在しない worktree は経過時間の誤読を防ぐため "-" 表示とする
                        worktree.lastCommitAt > 0 ? Terminal.elapsed(worktree.idleSeconds) : "-"]
            })
    }
    return 0
}
