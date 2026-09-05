import Foundation
import RepositoryGitHub

/// Organization でまとめられる状態かを確認する。
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
public enum CheckOrganizationAvailability {
    /// 使えないという答えを持ち越す時間
    private static let recheckInterval: TimeInterval = 60

    public static func check() -> Bool {
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

    private static var readiness: Bool?
    private static var lastCheck: Date?
    private static let lock = NSLock()
}
