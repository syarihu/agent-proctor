import Foundation

public enum Worktree {
    /// worktree の置き場が git の無視対象でなければ .git/info/exclude に足す。
    ///
    /// worktree は親リポジトリから見ると untracked なディレクトリとして現れるので、
    /// 放っておくと git status が常に汚れる。共有される .gitignore ではなく
    /// そのマシンだけで効く exclude に書く。
    public static func ensureIgnored(repo: String, relativeDir: String) throws {
        let probe = relativeDir.hasSuffix("/") ? relativeDir : relativeDir + "/"
        if gitOK(repo, "check-ignore", "-q", probe) { return }

        let info = try commonGitDir(repo: repo).appendingPathComponent("info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let exclude = info.appendingPathComponent("exclude")

        let existing = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        // Python の splitlines() と同じく末尾の改行で空行を作らない。
        // 直前の行が空かどうかで区切りの改行を足すか決めるので、ここがずれると
        // 追記のたびに空行が増える
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
    public static func setup(repo: String, worktree: String, config: RepoConfig) throws {
        for name in config.copyFiles {
            let src = URL(fileURLWithPath: repo).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = URL(fileURLWithPath: worktree).appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.copyItem(at: src, to: dst)
            info("  \(name) をコピーしました")
        }

        guard config.copyGitExclude else { return }
        let src = try commonGitDir(repo: repo)
            .appendingPathComponent("info").appendingPathComponent("exclude")
        guard FileManager.default.fileExists(atPath: src.path) else { return }

        // worktree の gitdir は .git/worktrees/<名前> 配下にあり、info/exclude は共有されない
        var gitdir = URL(fileURLWithPath: try git(worktree, "rev-parse", "--git-dir"))
        if !gitdir.path.hasPrefix("/") {
            gitdir = URL(fileURLWithPath: worktree).appendingPathComponent(gitdir.path)
        }
        let dstDir = gitdir.appendingPathComponent("info")
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)
        let dst = dstDir.appendingPathComponent("exclude")
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: src, to: dst)
        info("  .git/info/exclude を引き継ぎました")
    }

    private static func commonGitDir(repo: String) throws -> URL {
        let out = try git(repo, "rev-parse", "--git-common-dir")
        if out.hasPrefix("/") { return URL(fileURLWithPath: out) }
        return URL(fileURLWithPath: repo).appendingPathComponent(out)
    }

    public static func mergeBase(worktree: String, base: String) -> String {
        (try? git(worktree, "merge-base", "origin/\(base)", "HEAD",
                  check: false, quiet: true)) ?? ""
    }

    /// まだ git に追加されていないファイル。
    /// エージェントが作った新規ファイルはここに出る。
    public static func untrackedFiles(worktree: String) -> [String] {
        let out = (try? git(worktree, "ls-files", "--others", "--exclude-standard",
                            check: false, quiet: true)) ?? ""
        guard !out.isEmpty else { return [] }
        return out.components(separatedBy: "\n")
    }

    /// 作業量を数える。
    ///
    /// 新規ファイルは git diff に出ないため untracked として別に数える。
    /// エージェントの成果はファイル追加であることが多く、ここが漏れると
    /// 「何もしていない」ように見えてしまう。
    ///
    /// fromHead が true のときは HEAD からの差分、つまり未コミットの変更だけを見る。
    /// taskhub が作った worktree はブランチ全体がそのタスクの成果なのでベースから
    /// 数えるが、もともと開いていた対話セッションでベースから数えると
    /// ブランチの歴史がまるごと出てしまい、今の作業量が分からなくなる。
    public static func diffCounts(worktree: String, base: String,
                                  fromHead: Bool = false) -> DiffCounts {
        var counts = DiffCounts()
        let point = fromHead ? "HEAD" : mergeBase(worktree: worktree, base: base)
        if !point.isEmpty {
            let out = (try? git(worktree, "diff", "--shortstat", point,
                                check: false, quiet: true)) ?? ""
            counts.added = firstNumber(in: out, before: "insertion")
            counts.removed = firstNumber(in: out, before: "deletion")
        }
        counts.untracked = untrackedFiles(worktree: worktree).count
        return counts
    }

    /// "3 files changed, 12 insertions(+), 4 deletions(-)" から数を取る
    private static func firstNumber(in text: String, before keyword: String) -> Int {
        guard let range = text.range(of: "\\d+ \(keyword)", options: .regularExpression)
        else { return 0 }
        return Int(text[range].split(separator: " ")[0]) ?? 0
    }

    /// diffCounts の結果を人向けの1セルに整形する。CLI の表だけが使う。
    public static func format(_ counts: DiffCounts) -> String {
        var parts: [String] = []
        if counts.added > 0 { parts.append(color("32", "+\(counts.added)")) }
        if counts.removed > 0 { parts.append(color("31", "-\(counts.removed)")) }
        if counts.untracked > 0 { parts.append(color("36", "?\(counts.untracked)")) }
        return parts.joined(separator: " ")
    }
}
