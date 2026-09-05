import Foundation
import Model
import Utility

/// git への問い合わせ。git を呼ぶのはここだけにする。
///
/// proctor は worktree を作らないし消さないので、ここにあるのは
/// 「今どうなっているか」を聞く操作だけ。リポジトリを書き換える操作は持たない。
public enum GitClient {
    /// git コマンド実行時の共通プレフィックス。
    ///
    /// `GIT_OPTIONAL_LOCKS=0`:
    /// `git diff` 等が stat キャッシュ更新のために `index.lock` を取得してファイル書き込みを行うのを防ぐ。
    /// エージェントが実行中の git 操作とのロック競合や、ファイル監視の不要な再帰トリガーを防止するため。
    /// 古い git でも安全に無視されるよう、フラグではなく環境変数として設定する。
    private static let prefix = ["GIT_OPTIONAL_LOCKS=0", "git", "-C"]

    /// (成功したか, stdout)。失敗と「結果が空」を区別したいときに使う。
    public static func capture(_ repo: String, _ args: String...) -> (ok: Bool, output: String) {
        ProcessRunner.capture(prefix + [repo] + args)
    }

    /// 静かに聞く。答えが得られなければ空文字。
    public static func ask(_ repo: String, _ args: String...) -> String {
        ProcessRunner.capture(prefix + [repo] + args).output
    }

    // MARK: - 場所

    /// worktree 専用の管理ディレクトリ (`<リポジトリ>/.git/worktrees/<名前>`)。メイン worktree の場合は nil。
    ///
    /// コミット操作は作業ツリー自体ではなく、この管理ディレクトリおよび共有 refs/objects に書き込まれるため、
    /// コミット検知には作業ツリーとこの管理ディレクトリの両方を監視する必要がある。
    ///
    /// 連結 worktree の `.git` は `gitdir: <パス>` 形式のファイルであるため、
    /// プロセス起動コストを避けるため git コマンドを介さず直接ファイルを読み取って判定する。
    public static func adminDirectory(of worktree: String) -> String? {
        let dotGit = worktree + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first,
              line.hasPrefix("gitdir:") else { return nil }
        // CRLF の \r を含めてトリムする
        let path = line.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }
        return path.hasPrefix("/") ? path : worktree + "/" + path
    }

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
        let resolved = common.resolvingSymlinksInPath()
        // ベアリポジトリでは共通の .git 自体をリポジトリルートとする。
        // 親ディレクトリを返すと作業ツリー外の配置先ディレクトリを指してしまい、worktree 一覧等が取得できなくなるため。
        let (asked, bare) = capture(resolved.path, "rev-parse", "--is-bare-repository")
        if asked, bare == "true" { return resolved.path }
        return resolved.deletingLastPathComponent().path
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

    // MARK: - worktree

    /// `git worktree list --porcelain` の1件ぶん。読んだままの形。
    ///
    /// 「片付けてよいか」の判断はここでは持たない (それは UseCase の仕事)。
    public struct WorktreeEntry: Equatable {
        /// 登録されているパス。symlink は解決済み。
        /// 台帳のパス (GitClient.toplevel が解決している) と突き合わせるので、
        /// 片方だけ生のままだと /tmp と /private/tmp が別物になり、
        /// 動いているセッションが worktree に結び付かなくなる
        public var path: String
        /// ブランチ名 ("refs/heads/" は落としてある)。detached なら nil
        public var branch: String?
        public var isDetached: Bool
        /// 手で外れないよう鍵が掛かっているもの。消してよいか決めるのに使う
        public var isLocked: Bool
        /// git が「実体を失っている」と見なしているもの
        public var isPrunable: Bool
        /// ベアリポジトリ本体。作業する場所ではないので、数える対象から外す
        public var isBare: Bool
    }

    /// そのリポジトリに登録されている worktree。先頭がメイン worktree。
    ///
    /// git がその順で出すので並べ替えない。呼ぶ側は先頭を本体として扱える。
    public static func worktrees(_ repo: String) -> [WorktreeEntry] {
        // NUL 区切りで読む。素の --porcelain は1属性1行で出すので、
        // パスに改行が入っていると1件が2件に割れて別物になる。
        //
        // -z (NUL区切り) を優先して使用する。パスに改行を含む場合の誤分割を防ぐため。
        // 未対応の git バージョンでは改行区切りの porcelain 出力にフォールバックする。
        let (ok, output) = capture(repo, "worktree", "list", "--porcelain", "-z")
        if ok, output.contains("\0") { return parse(output, separator: "\0") }

        let (plainOk, plain) = capture(repo, "worktree", "list", "--porcelain")
        guard plainOk, !plain.isEmpty else { return [] }
        return parse(plain, separator: "\n")
    }

    /// 属性の並びを1件ずつに畳む。区切りは呼ぶ側が決める (NUL か改行)
    private static func parse(_ output: String, separator: String) -> [WorktreeEntry] {
        var entries: [WorktreeEntry] = []
        var current: WorktreeEntry?
        func flush() {
            if let current { entries.append(current) }
            current = nil
        }
        for line in output.components(separatedBy: separator) {
            if line.hasPrefix("worktree ") {
                flush()
                let raw = String(line.dropFirst("worktree ".count))
                current = WorktreeEntry(
                    path: URL(fileURLWithPath: raw).resolvingSymlinksInPath().path,
                    branch: nil, isDetached: false, isLocked: false,
                    isPrunable: false, isBare: false)
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst("branch ".count))
                current?.branch = ref.hasPrefix("refs/heads/")
                    ? String(ref.dropFirst("refs/heads/".count)) : ref
            } else if line == "detached" {
                current?.isDetached = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.isLocked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.isPrunable = true
            } else if line == "bare" {
                current?.isBare = true
            }
        }
        flush()
        return entries
    }

    /// 取り込み先になるブランチ。`origin/main` のような remote 側を優先する。
    ///
    /// 手元の main は取り残されていることがある。マージは向こう側で起きるので、
    /// 手元の main と比べると「まだマージされていない」と読み違える。
    /// remote を追う参照が無いときだけ手元のブランチに落とす。
    public static func defaultBranch(_ repo: String) -> String? {
        let (ok, head) = capture(repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD")
        if ok, !head.isEmpty { return head }
        for candidate in ["origin/main", "origin/master", "main", "master"] {
            let (found, _) = capture(repo, "rev-parse", "--verify", "--quiet", candidate)
            if found { return candidate }
        }
        return nil
    }

    /// base にマージ済みのブランチ一覧を取得する。
    /// squash merge されたものは履歴が連続しないため検知できない（PR側のステータス判定で補完する）。
    public static func mergedBranches(_ repo: String, into base: String) -> Set<String> {
        let (ok, output) = capture(repo, "branch", "--merged", base,
                                   "--format=%(refname:short)")
        guard ok, !output.isEmpty else { return [] }
        return Set(output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    /// いちばん新しいコミットの時刻 (epoch 秒)。読めなければ 0。
    /// 「いつから放置されているか」を出すのに使う
    public static func lastCommitAt(_ worktree: String) -> Int {
        Int(ask(worktree, "log", "-1", "--format=%ct")) ?? 0
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

    /// 未追跡 (untracked) ファイルの件数を取得する。
    /// 取得失敗時に 0 ではなく nil を返すことで、未追跡ファイルの存在する worktree が誤ってクリーンとみなされるのを防ぐ。
    /// 配列の生成を避けて改行数をカウントすることで高速化する。
    public static func untrackedCount(_ worktree: String) -> Int? {
        let (ok, out) = capture(worktree, "ls-files", "--others", "--exclude-standard")
        guard ok else { return nil }
        return out.isEmpty ? 0 : out.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }

    /// 差分行数（追加・削除・バイナリファイル数・変更ファイル総数）を集計する。取得失敗時は nil。
    ///
    /// リネームや権限変更など行数が出ない差分や、バイナリ差分を漏れなく検知するため
    /// `--shortstat` ではなく `--numstat` を用いて変更ファイル総数を集計する。
    public static func changedLines(_ worktree: String, since point: String)
        -> (added: Int, removed: Int, binary: Int, files: Int)? {
        let (ok, out) = capture(worktree, "diff", "--numstat", point)
        guard ok else { return nil }
        var added = 0, removed = 0, binary = 0, files = 0
        for line in out.split(separator: "\n") {
            // パース失敗時も行が出力された以上変更ありとしてカウントする
            files += 1
            guard let firstTab = line.firstIndex(of: "\t") else { continue }
            let tail = line[line.index(after: firstTab)...]
            guard let secondTab = tail.firstIndex(of: "\t") else { continue }
            let insertions = line[..<firstTab]
            let deletions = tail[..<secondTab]
            // バイナリファイルは行数の代わりに "-" が出力される
            if insertions == "-" || deletions == "-" { binary += 1; continue }
            added += Int(insertions) ?? 0
            removed += Int(deletions) ?? 0
        }
        return (added, removed, binary, files)
    }
}
