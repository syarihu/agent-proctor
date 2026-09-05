import Foundation

/// GitHub への問い合わせ。gh (GitHub CLI) を呼ぶのはここだけにする。
///
/// **自分で API を叩かないのは、認証を持ちたくないから。** トークンの置き場も
/// 更新も gh が面倒を見ているし、GitHub Enterprise のホストもそちらの設定に乗る。
/// proctor は台帳を読んで見せるだけの道具なので、資格情報には触れないでおく。
public enum GitHubClient {
    /// gh の実行ファイル。見つからなければ nil。
    ///
    /// **PATH だけを頼りにできない。** .app として (Finder やログイン項目から)
    /// 起動されたときの PATH は `/usr/bin:/bin:/usr/sbin:/sbin` しかなく、
    /// Homebrew の入れ先はそこに入っていない。PATH だけを見ていると、
    /// 端末からは動くのにアプリからだけ「gh が無い」ことになる。
    /// よくある置き場を先に当たるのは、当たればプロセスを起こさずに済むため
    public static let executable: String? = {
        let known = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let found = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let (ok, path) = ProcessRunner.capture(["which", "gh"])
        return ok && !path.isEmpty ? path : nil
    }()

    /// 資格情報が入っているか。**聞くだけで、覚えない。**
    /// いつ聞き直すかは方針なので `OrganizationGrouping` が持つ。
    ///
    /// **`gh auth status` ではなく `gh auth token` を使う。** status のほうは
    /// トークンが今も生きているかを GitHub に問い合わせに行くので、
    /// **ネットワークが無いと、正しくログインしていても失敗する**
    /// (実測で 0.4〜1.8 秒かかり、届かない相手だと60秒返ってこない)。
    /// それを「使えない」と読むと、オフラインで立ち上げただけで一覧の
    /// まとめ方が変わってしまう。token のほうは手元の資格情報を読むだけで
    /// 0.04 秒で返る。トークンが失効していれば結局アイコンが取れないだけなので、
    /// 確かめたいこと (gh に頼れるか) には手元を見れば足りる
    public static func hasCredentials() -> Bool {
        guard let gh = executable else { return false }
        return ProcessRunner.capture([gh, "auth", "token"]).ok
    }

    /// そのブランチに紐づく PR を1つ引く。
    ///
    /// **`gh pr view` ではなく `gh pr list` を使う。** view のほうは PR が
    /// 無いときも非0で終わるので、**「無い」と「聞けなかった」が終了コードから
    /// 見分けられない**。list なら、無いときは空の配列を返して正常終了し、
    /// 認証が切れているときや git の外で呼ばれたときだけ非0になる。
    /// 見分けが付かないまま覚えると、gh が使えないだけの状態が
    /// 「PR は無い」として焼き付く (`PullRequestLookup` の説明)。
    ///
    /// **`--state all` を落とさないこと。** 既定は open だけなので、
    /// マージした PR を取りこぼす。作業が終わったあとにこそ
    /// 「どの PR になったか」を見たい。新しいものから返るので先頭を採る。
    ///
    /// **branch は呼ぶ側から受け取る。** 台帳の branch は登録した時点の値で、
    /// セッションの途中で `git switch` すればずれる。PR はブランチに紐づくので、
    /// ずれた名前で引くと**別のブランチの PR を開かせる**ことになる。
    ///
    /// - Parameters:
    ///   - worktree: どのリポジトリに聞くかを gh に決めさせるための場所
    ///   - branch: いま実際に出ているブランチ名
    public static func pullRequest(worktree: String, branch: String) -> PullRequestLookup {
        // detached の `rev-parse --abbrev-ref` は "HEAD" を返す。台帳が
        // ブランチを持たないときに入れる "-" ともども、名前ではないので聞かない
        guard let gh = executable,
              !branch.isEmpty, branch != "HEAD", branch != "-" else { return .unavailable }
        // 待ち切りを入れるのは、届かないホストだと gh が1分近く黙るため。
        // 呼ぶのは常駐しているアプリなので、返らない問い合わせを残せない
        let (ok, output) = ProcessRunner.capture(
            [gh, "pr", "list", "--head", branch, "--state", "all", "--limit", "1",
             "--json", "number,url,state,isDraft,title"],
            cwd: worktree, timeout: 15)
        guard ok, let data = output.data(using: .utf8),
              let found = try? JSONDecoder().decode([PullRequestRef].self, from: data) else {
            return .unavailable
        }
        return found.first.map(PullRequestLookup.found) ?? .absent
    }

    /// 持ち主のアイコンの URL。user でも organization でも同じ口で引ける。
    ///
    /// GitHub 以外のホストは相手にしない。gh は GitHub 専用の道具で、
    /// GitLab などに向けても答えを持っていない
    public static func avatarURL(owner: String, host: String = "github.com") -> String? {
        guard host == "github.com", let gh = executable else { return nil }
        let (ok, url) = ProcessRunner.capture(
            [gh, "api", "users/\(owner)", "--jq", ".avatar_url"])
        return ok && !url.isEmpty ? url : nil
    }

    /// アイコンを1つ落として置く。置けたかどうかだけ返す。
    ///
    /// 落とすのに gh を使わないのは、アイコンの実体が API のホストではなく
    /// avatars.githubusercontent.com にあるため。gh api は API のホストへ向ける
    /// 道具で、認証ヘッダを別のホストへ持って行かせたくない。
    ///
    /// いったん隣に落としてから置き換えるのは、途中で切れた画像を残さないため。
    /// 壊れたファイルが居座ると、期限が切れるまで毎回それを読もうとする。
    ///
    /// **落とす先の名前は毎回変える。** 同じ相手を2人が同時に取りに来たとき、
    /// 置き場が1つだと後から来たほうの curl が先の書き込み中のファイルに
    /// 書き足してしまう。**`replaceItemAt` で入れ替えるのも同じ理由で、**
    /// 「消してから移す」にすると入れ替えに失敗したときに、それまで出ていた
    /// アイコンまで道連れになる
    public static func downloadAvatar(from url: String, to destination: URL) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).part")
        defer { try? manager.removeItem(at: partial) }

        // 大きさに上限を置くのは、相手が返すものを丸ごと信じないため。
        // アイコン1枚に何百 MB も要ることはない
        let (ok, _) = ProcessRunner.capture(
            ["curl", "-fsSL", "--max-time", "20", "--max-filesize", "8388608",
             "-o", partial.path, url])
        guard ok else { return false }

        // 無ければ移すだけで済む。**失敗しても諦めずに置き換えへ回す。**
        // 「無いか確かめる」と「移す」の間に他の誰かが置き終えていることがあり、
        // そこで打ち切ると、取れているのに nil を返して呼ぶ側を空振りさせる
        if !manager.fileExists(atPath: destination.path),
           (try? manager.moveItem(at: partial, to: destination)) != nil {
            return true
        }
        return (try? manager.replaceItemAt(destination, withItemAt: partial)) != nil
    }
}
