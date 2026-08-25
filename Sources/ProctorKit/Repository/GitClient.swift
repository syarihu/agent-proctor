import Foundation

/// git への問い合わせ。git を呼ぶのはここだけにする。
///
/// proctor は worktree を作らないし消さないので、ここにあるのは
/// 「今どうなっているか」を聞く操作だけ。リポジトリを書き換える操作は持たない。
public enum GitClient {
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
    /// その親がメインリポジトリになる。一覧をプロジェクトごとにまとめるのに使う。
    public static func mainWorktree(from start: String) -> String? {
        let (ok, output) = capture(start, "rev-parse", "--git-common-dir")
        guard ok, !output.isEmpty else { return nil }
        let common = output.hasPrefix("/")
            ? URL(fileURLWithPath: output)
            : URL(fileURLWithPath: start).appendingPathComponent(output)
        return common.resolvingSymlinksInPath().deletingLastPathComponent().path
    }

    /// セッションが動いている場所のルート。
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

    // MARK: - remote

    /// 取ってくる先の URL。1つも無ければ nil。
    ///
    /// origin を先に見て、無ければ最初に見つかった remote を使う。
    /// origin 決め打ちにしないのは、fork を upstream 側の名前で持っている置き方や、
    /// remote 名を付け替えている置き方があるため。
    public static func remoteURL(_ repo: String) -> String? {
        let (ok, origin) = capture(repo, "remote", "get-url", "origin")
        if ok, !origin.isEmpty { return origin }
        let (listed, names) = capture(repo, "remote")
        guard listed, let first = names.split(separator: "\n").first else { return nil }
        let (found, url) = capture(repo, "remote", "get-url", String(first))
        return found && !url.isEmpty ? url : nil
    }

    // MARK: - 差分

    /// まだ git に追加されていないファイル。
    /// エージェントが作った新規ファイルはここに出る。
    public static func untrackedFiles(_ worktree: String) -> [String] {
        let out = ask(worktree, "ls-files", "--others", "--exclude-standard")
        return out.isEmpty ? [] : out.components(separatedBy: "\n")
    }

    /// 追加行数・削除行数。point からの差分を数える。
    public static func changedLines(_ worktree: String,
                                    since point: String) -> (added: Int, removed: Int) {
        let out = ask(worktree, "diff", "--shortstat", point)
        return (number(in: out, before: "insertion"), number(in: out, before: "deletion"))
    }

    /// "3 files changed, 12 insertions(+), 4 deletions(-)" から数を取る
    private static func number(in text: String, before keyword: String) -> Int {
        guard let range = text.range(of: "\\d+ \(keyword)", options: .regularExpression)
        else { return 0 }
        return Int(text[range].split(separator: " ")[0]) ?? 0
    }
}
