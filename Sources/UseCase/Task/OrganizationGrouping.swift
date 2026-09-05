import Foundation

/// 一覧を Organization でまとめるために要るもの。
///
/// 持ち主そのものは git の remote から読める (`ResolveRepoOrigin`) ので、
/// ここが持つのはそれ以外の2つ ——「そのまとめ方を選ばせてよいか」と
/// 「見出しに出すアイコンをどう手に入れるか」。
///
/// **いつ聞き直すかの間隔はすべてここに置く。** gh に聞くのも
/// (`GitHubClient`)、置き場を出し入れするのも (`AvatarCache`) 向こうの仕事で、
/// 「何秒で古いと見なすか」はどちらでもない。
public enum OrganizationGrouping {
    /// Organization でまとめられる状態か。
    ///
    /// **アイコンが引ける見込みが無いなら、このまとめ方は選ばせない。** 持ち主の
    /// 名前だけの見出しになると、リポジトリごとにまとめるのとほとんど変わらない上に、
    /// なぜアイコンが出ないのかも画面からは分からない。選べないほうが、
    /// 「何かが足りない」と気づける。
    ///
    /// **見ているのは資格情報があるかどうかまで** (`hasCredentials`)。
    /// 生きているかまでは確かめないので、失効したトークンが残っていれば
    /// ここは true を返し、見出しが全部モノグラムになる。それでもこちらを取るのは、
    /// 生死を確かめる問い合わせがネットワークに出るため —— オフラインで
    /// 立ち上げただけで一覧のまとめ方が変わるほうが、ずっと分かりにくい。
    ///
    /// 答えは覚えておく。プロセスを起こす問い合わせを、描き直しのたびに
    /// 走らせたくない。ただし**使えないという答えだけは持ち越さない** ——
    /// あとから `gh auth login` したときに、アプリを立ち上げ直さないと
    /// 気づけないのは分かりにくい。
    ///
    /// **聞いている間はロックを離す。** 抱えたまま待つと、アイコンを取りに来た
    /// 全員がその後ろに並ぶ。まれに二重に聞くことになるが、手元を読むだけの
    /// 安い問い合わせ (0.04 秒) なので、並ばせるより聞き直すほうがよい。
    ///
    /// **「聞きに行った」の印は、答えが出てから立てる。** 聞く前に立てると、
    /// その 40 ミリ秒のあいだに入ってきた呼び出しが「さっき聞いたばかりだ」と
    /// 読んで**答えを待たずに false を返す**。起動直後は可否の確認と組織ごとの
    /// アイコン取得が同時に走るので、8本同時なら7本が false を掴み、
    /// アイコンが1枚も落ちてこないうえ、外れた組織は10分のクールダウンに入る。
    /// 二重に聞くことより、嘘を返さないことを取る
    public static func isAvailable() -> Bool {
        lock.lock()
        if readiness == true {
            lock.unlock()
            return true
        }
        if let checked = lastCheck, Date().timeIntervalSince(checked) < recheckInterval {
            lock.unlock()
            return false
        }
        lock.unlock()

        let ready = GitHubClient.hasCredentials()

        lock.lock()
        readiness = ready
        lastCheck = Date()
        lock.unlock()
        return ready
    }

    /// 見出しに出すアイコンを1つ手に入れる。
    ///
    /// 手元にあればそれを返し、無ければ gh に聞いて落としてくる。
    ///
    /// - Returns: 画像ファイルの場所。手に入らなければ nil (呼ぶ側は代わりの絵を描く)
    public static func avatar(owner: String, host: String = "github.com") -> URL? {
        guard host == "github.com", !owner.isEmpty,
              let file = AvatarCache.file(for: owner) else { return nil }
        let age = AvatarCache.age(of: owner)

        // 期限内のものがあれば、それで済ませる
        if let age, age < maxAge { return file }
        // 少し前に失敗した相手には、しばらく聞きに行かない。取れない理由
        // (ネットワークが無い・組織が private) は次の描き直しでも変わらないことが多く、
        // 一覧を開くたびに gh が起きることになる
        guard !isCoolingDown(owner) else { return age == nil ? nil : file }

        guard isAvailable(),
              let url = GitHubClient.avatarURL(owner: owner, host: host),
              GitHubClient.downloadAvatar(from: url, to: file) else {
            noteFailure(owner)
            // 取り直せなくても、古いものが残っていればそれを出す。
            // 一度出ていたアイコンが消えるほうが、少し古い絵より落ち着かない
            return age == nil ? nil : file
        }
        clearFailure(owner)
        return file
    }

    /// 手元の1枚を捨てる。**読めなかったときに呼んでもらう。**
    ///
    /// 置き場は「いつ書かれたか」しか見ていないので、中身が壊れていても
    /// 期限が切れるまで同じものを返し続ける。読めたかどうかを知っているのは
    /// 画像を開いた側だけなので、捨てる合図はそちらから受ける。
    /// 失敗の記録も一緒に消して、次にすぐ取り直せるようにする
    public static func discardAvatar(owner: String) {
        AvatarCache.discard(owner)
        clearFailure(owner)
    }

    /// 取り直すまでの間隔。組織のアイコンが差し替わっても1週間で追いつく
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// 取れなかった相手に聞き直すまでの間隔
    private static let retryInterval: TimeInterval = 10 * 60
    /// 使えないという答えを持ち越す時間
    private static let recheckInterval: TimeInterval = 60

    private static func isCoolingDown(_ owner: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let failed = failures[owner] else { return false }
        return Date().timeIntervalSince(failed) < retryInterval
    }

    private static func noteFailure(_ owner: String) {
        lock.lock()
        failures[owner] = Date()
        lock.unlock()
    }

    private static func clearFailure(_ owner: String) {
        lock.lock()
        failures.removeValue(forKey: owner)
        lock.unlock()
    }

    private static var failures: [String: Date] = [:]
    private static var readiness: Bool?
    private static var lastCheck: Date?
    private static let lock = NSLock()
}
