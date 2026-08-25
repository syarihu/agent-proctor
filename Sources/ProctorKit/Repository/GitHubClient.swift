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
    static let executable: String? = {
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
