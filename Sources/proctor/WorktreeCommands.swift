import Foundation
import ProctorKit

/// worktree の一覧。セッションではなく**場所**を並べる。
///
/// セッションが終わっても worktree は残るので、`ls` では見えない
/// 「誰も使っていない作業場」がここに出る。片付けの判断材料になる列
/// (取り込み済みか・未コミットがあるか・どれだけ放置されているか) を並べる。
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
    let repos = CollectWorktrees.run(repo: repo, allRepos: all || repo == nil)

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
                        // コミットが1つも無い worktree では経過を出さない
                        // (0 と出すと「たった今まで使っていた」に見える)
                        worktree.lastCommitAt > 0 ? Terminal.elapsed(worktree.idleSeconds) : "-"]
            })
    }
    return 0
}
