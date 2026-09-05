import Foundation

/// git への問い合わせ。git を呼ぶのはここだけにする。
///
/// proctor は worktree を作らないし消さないので、ここにあるのは
/// 「今どうなっているか」を聞く操作だけ。リポジトリを書き換える操作は持たない。
public enum GitClient {
    /// すべての git に付ける前置き。
    ///
    /// **聞くだけのつもりで書かせないために `GIT_OPTIONAL_LOCKS=0` を渡す。**
    /// `git diff` は stat キャッシュを新しくするために `index.lock` を取って
    /// インデックスを書き戻す。proctor が覗く worktree は、まさにエージェントが
    /// 自分で git を叩いている最中の場所なので、見張っているだけのこちらが
    /// 向こうのロックを取り合うことになる。書き戻しは見張りも起こすので、
    /// 数えた自分がその報せでまた数え直す形にもなる。
    ///
    /// **同じ意味の `--no-optional-locks` ではなく環境変数にしてある。**
    /// あのフラグは git 2.15 からで、知らない git は `unknown option` で
    /// 落ちる —— 前置きなので**全部の呼び出しが失敗して一覧が真っ白になる**。
    /// 知らない環境変数のほうは、どの版も黙って無視する。
    /// 走らせるのが `/usr/bin/env` なので、ここに置くだけで渡せる
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

    /// その worktree のためだけに git が使う置き場
    /// (`<リポジトリ>/.git/worktrees/<名前>`)。リポジトリ本体なら nil。
    ///
    /// **コミットは作業ツリーの中では起きない。** 書かれるのはここと、
    /// 共有の `objects`/`refs` のほうで、作業ツリーのファイルは1つも動かない。
    /// 変化を見張る側 (`WorktreeWatcher`) は、作業ツリーとここの両方を見ないと
    /// コミットに気づけず、空になったはずの差分を出し続けることになる。
    ///
    /// 連結 worktree の `.git` は `gitdir: <パス>` の1行だけのファイルで、
    /// リポジトリ本体の `.git` はディレクトリ。この違いで見分ける。
    /// **git は起こさない** —— 1行読めば分かる答えのために
    /// `rev-parse --git-dir` を使うと、数え直しのたびに worktree の数だけ
    /// プロセスが増える
    public static func adminDirectory(of worktree: String) -> String? {
        let dotGit = worktree + "/.git"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
              let line = text.split(separator: "\n").first,
              line.hasPrefix("gitdir:") else { return nil }
        // 改行ごと落とす。`.whitespaces` は空白とタブだけなので、
        // CRLF で書かれていると `\r` が残り、その先が見つからなくなる
        let path = line.dropFirst("gitdir:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty { return nil }
        // 相対で書かれている置き方もある。その worktree から見た位置になる
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
        // ベアリポジトリでは共通の .git そのものが本体。親を返すと
        // repo.git を置いてあるだけのディレクトリを指してしまい、
        // そこで git を叩いても何も出てこない (worktree の一覧が空になる)
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
        // -z は git 2.36 から。**旗を知らない git は、失敗するとは限らない。**
        // 黙って無視して改行区切りのまま返されると、NUL で切っても全文が
        // 1つのままになり、一覧まるごとを1つのパスとして読んでしまう。
        // 区切りが本当に入っているかで見分けて、入っていなければ改行で読み直す
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

    /// base に取り込まれ済みのブランチ名。
    ///
    /// worktree ごとに聞かない。1件ずつ `merge-base` を回すと worktree の数だけ
    /// git が起きるが、答えはリポジトリ単位で一度に取れる。
    ///
    /// **squash merge は見抜けない。** GitHub で squash された PR は歴史が繋がらないので、
    /// ここには出てこない。ローカルだけで証明できるのはここまでで、
    /// 取りこぼしは PR の状態を見に行ける側 (skill) が補う
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

    /// まだ git に追加されていないファイルの数。
    /// エージェントが作った新規ファイルはここに出る。
    ///
    /// **聞けなかったときは nil。** 「0件だった」と区別が付かないと、
    /// 読めない worktree が「変更なし = 消してよい」に化ける
    ///
    /// **パスを組み立てずに改行だけ数える。** 呼ぶ側はどちらも件数しか見ないのに、
    /// 一覧を作ると1行ごとに String を確保することになる。未追跡5万件で
    /// 実測6.0ミリ秒、数えるだけなら0.71ミリ秒だった
    public static func untrackedCount(_ worktree: String) -> Int? {
        let (ok, out) = capture(worktree, "ls-files", "--others", "--exclude-standard")
        guard ok else { return nil }
        // 出力は前後の改行を落としてあるので、行数は「改行の数 + 1」。
        // 空文字だけは0件 (そのまま数えると1件になってしまう)。
        // Character ではなく UTF-8 のバイトで数えるのは、書記素の切り出しを
        // させないため。改行のバイト (0x0A) は多バイト文字の途中には現れないので
        // 取り違えようがなく、"\r\n" を1文字と見なす Character 側と違って
        // 元の components(separatedBy: "\n") と数が合う
        return out.isEmpty ? 0 : out.utf8.reduce(1) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
    }

    /// 追加行数・削除行数、行では数えられなかったファイルの数、
    /// そして変わったファイルの総数。point からの差分を数える。聞けなければ nil
    ///
    /// **`files` を別に返すのは、行数もバイナリの印も出ない変更があるため。**
    /// 純粋なリネームは `0<TAB>0<TAB>old => new`、モード変更 (chmod +x) も
    /// `0<TAB>0<TAB>path` で出る。行数だけを見ると全部 0 なので「変更なし」と
    /// 見分けが付かず、バイナリのときと同じ経路で `isRemovable` が
    /// 「消してよい」と言い出す。**numstat が行を出した = そのファイルは変わった**
    /// と読み替えて、行数が語れないぶんを総数で受け止める
    ///
    /// **`--shortstat` ではなく `--numstat` を使う。** shortstat はバイナリの変更を
    /// `1 file changed, 0 insertions(+), 0 deletions(-)` と報告するので、
    /// 数だけ見ると「変更なし」と見分けが付かない。そうなると `DiffCounts.isEmpty` が
    /// true になり、**未コミットのバイナリ変更しか無い worktree が
    /// `CollectedWorktree.isRemovable` で「消してよい候補」に出る**。
    /// worktree を消すのは控えのない仕事を捨てることなので、ここは取り違えられない。
    /// numstat ならバイナリは `-<TAB>-<TAB>パス` で出るので、その場で見分けられる。
    /// 速さも変わらない (実測 numstat 18ミリ秒、shortstat 20ミリ秒)
    public static func changedLines(_ worktree: String, since point: String)
        -> (added: Int, removed: Int, binary: Int, files: Int)? {
        let (ok, out) = capture(worktree, "diff", "--numstat", point)
        guard ok else { return nil }
        var added = 0, removed = 0, binary = 0, files = 0
        for line in out.split(separator: "\n") {
            // **読めなかった行も1件として数える。** タブが足りない行は numstat の
            // 形になっていないが、git がその行を出した以上ファイルは変わっている。
            // 読めないことを「変わっていない」に倒すと、まさにここで塞いだ
            // 「変更が無いように見えて消される」を作り直すことになる。
            // 数える位置を guard より前に置いてあるのはそのため
            files += 1
            // **タブは先頭2つしか見ない。** 3つ目から先はパスの一部で、
            // パスにタブが入っていても (git は quotePath で括るが、
            // core.quotePath を切っている置き方もある) 数え違えないようにする
            guard let firstTab = line.firstIndex(of: "\t") else { continue }
            let tail = line[line.index(after: firstTab)...]
            guard let secondTab = tail.firstIndex(of: "\t") else { continue }
            let insertions = line[..<firstTab]
            let deletions = tail[..<secondTab]
            // 行数の代わりに `-` が置かれているのがバイナリ。
            // 何行変わったかは言えないので、代わりに何個変わったかを数える
            if insertions == "-" || deletions == "-" { binary += 1; continue }
            added += Int(insertions) ?? 0
            removed += Int(deletions) ?? 0
        }
        return (added, removed, binary, files)
    }
}
