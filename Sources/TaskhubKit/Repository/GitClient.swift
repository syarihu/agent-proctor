import Foundation

/// git への問い合わせと操作。git を呼ぶのはここだけにする。
///
/// 「何を数えるか」「消してよいか」の判断は UseCase 側が持ち、
/// ここは聞かれたことに答えるだけにしておく。
public enum GitClient {
    @discardableResult
    public static func run(_ repo: String, _ args: String...,
                           check: Bool = true, quiet: Bool = false) throws -> String {
        try ProcessRunner.run(["git", "-C", repo] + args, check: check, quiet: quiet)
    }

    /// 終了コードだけを見たいとき用。出力は捨てる。
    public static func succeeds(_ repo: String, _ args: String...) -> Bool {
        ProcessRunner.capture(["git", "-C", repo] + args).ok
    }

    /// (成功したか, stdout)。失敗と「結果が空」を区別したいときに使う。
    public static func capture(_ repo: String, _ args: String...) -> (ok: Bool, output: String) {
        ProcessRunner.capture(["git", "-C", repo] + args)
    }

    /// 静かに聞く。答えが得られなければ空文字。
    public static func ask(_ repo: String, _ args: String...) -> String {
        ProcessRunner.capture(["git", "-C", repo] + args).output
    }

    // MARK: - 場所

    /// メイン worktree のパス。worktree の中から聞かれても本体を指す。
    ///
    /// --git-common-dir はどの worktree から見ても共通の .git を指すので、
    /// その親がメインリポジトリになる。
    public static func mainWorktree(from start: String) -> String? {
        let (ok, output) = capture(start, "rev-parse", "--git-common-dir")
        guard ok, !output.isEmpty else { return nil }
        return absolute(output, relativeTo: start)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent().path
    }

    /// いま居る worktree のルート。
    ///
    /// サブディレクトリで起動されていても同じタスクに寄せたいので正規化する。
    /// 台帳のパスと突き合わせるため、シンボリックリンクも解決しておく。
    /// 経路によって解決の有無が違うと、同じ場所を別物として扱ってしまう。
    public static func toplevel(from cwd: String) -> String {
        let (ok, top) = capture(cwd, "rev-parse", "--show-toplevel")
        guard ok, !top.isEmpty else { return "" }
        return URL(fileURLWithPath: top).resolvingSymlinksInPath().path
    }

    public static func currentBranch(_ repo: String) -> String {
        ask(repo, "rev-parse", "--abbrev-ref", "HEAD")
    }

    /// どの worktree からも共通の .git ディレクトリ
    public static func commonDir(_ repo: String) throws -> URL {
        absolute(try run(repo, "rev-parse", "--git-common-dir"), relativeTo: repo)
    }

    /// その worktree 専用の .git ディレクトリ (.git/worktrees/<名前>)
    public static func gitDir(_ worktree: String) throws -> URL {
        absolute(try run(worktree, "rev-parse", "--git-dir"), relativeTo: worktree)
    }

    private static func absolute(_ path: String, relativeTo base: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: base).appendingPathComponent(path)
    }

    // MARK: - ブランチ

    public static func hasLocalBranch(_ repo: String, _ branch: String) -> Bool {
        succeeds(repo, "rev-parse", "--verify", "refs/heads/\(branch)")
    }

    public static func hasRemoteBranch(_ repo: String, _ branch: String) -> Bool {
        succeeds(repo, "rev-parse", "--verify", "refs/remotes/origin/\(branch)")
    }

    /// origin/HEAD → develop/main/master の順にベースブランチを推定する。
    public static func detectBaseBranch(_ repo: String) -> String {
        let head = ask(repo, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
        if head.contains("/") {
            return String(head.split(separator: "/", maxSplits: 1)[1])
        }
        for candidate in ["develop", "main", "master"] where hasRemoteBranch(repo, candidate) {
            return candidate
        }
        return currentBranch(repo)
    }

    /// 消せたか。未マージで拒まれたときは false。
    @discardableResult
    public static func deleteBranch(_ repo: String, _ branch: String, force: Bool) -> Bool {
        succeeds(repo, "branch", force ? "-D" : "-d", branch)
    }

    // MARK: - worktree

    public static func addWorktree(_ repo: String, at path: String,
                                   branch: String, tracking remote: String?) throws {
        if let remote {
            try run(repo, "worktree", "add", "--track", "-b", branch, path, remote)
        } else {
            try run(repo, "worktree", "add", path, branch)
        }
    }

    public static func addWorktree(_ repo: String, at path: String,
                                   newBranch: String, from start: String) throws {
        try run(repo, "worktree", "add", "-b", newBranch, path, start)
    }

    public static func removeWorktree(_ repo: String, at path: String, force: Bool) throws {
        var args = ["worktree", "remove", path]
        if force { args.append("--force") }
        try ProcessRunner.run(["git", "-C", repo] + args)
    }

    public static func pruneWorktrees(_ repo: String) {
        _ = capture(repo, "worktree", "prune")
    }

    public static func fetchOrigin(_ repo: String) {
        _ = capture(repo, "fetch", "origin", "--quiet")
    }

    // MARK: - 差分

    public static func mergeBase(_ worktree: String, base: String) -> String {
        ask(worktree, "merge-base", "origin/\(base)", "HEAD")
    }

    /// まだ git に追加されていないファイル。
    /// エージェントが作った新規ファイルはここに出る。
    public static func untrackedFiles(_ worktree: String) -> [String] {
        let out = ask(worktree, "ls-files", "--others", "--exclude-standard")
        return out.isEmpty ? [] : out.components(separatedBy: "\n")
    }

    /// コミットしていない変更があるか。確かめられなければ nil。
    ///
    /// 「失敗した」を「変更なし」と読むと、守るための確認が素通りする。
    public static func dirtyState(_ worktree: String) -> Bool? {
        let (ok, output) = capture(worktree, "status", "--porcelain")
        return ok ? !output.isEmpty : nil
    }

    /// base に入っていないコミットの数。確かめられなければ nil。
    public static func commitsAhead(_ worktree: String, base: String) -> Int? {
        let (ok, output) = capture(worktree, "rev-list", "--count", "origin/\(base)..HEAD")
        guard ok else { return nil }
        return Int(output) ?? 0
    }

    /// 追加行数・削除行数。point からの差分を数える。
    public static func changedLines(_ worktree: String, since point: String) -> (added: Int, removed: Int) {
        let out = ask(worktree, "diff", "--shortstat", point)
        return (number(in: out, before: "insertion"), number(in: out, before: "deletion"))
    }

    /// "3 files changed, 12 insertions(+), 4 deletions(-)" から数を取る
    private static func number(in text: String, before keyword: String) -> Int {
        guard let range = text.range(of: "\\d+ \(keyword)", options: .regularExpression)
        else { return 0 }
        return Int(text[range].split(separator: " ")[0]) ?? 0
    }

    // MARK: - 無視の設定

    public static func isIgnored(_ repo: String, _ path: String) -> Bool {
        succeeds(repo, "check-ignore", "-q", path)
    }
}
