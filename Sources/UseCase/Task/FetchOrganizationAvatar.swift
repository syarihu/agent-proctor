import Foundation
import RepositoryGitHub
import Utility

/// Organization のアバターアイコンを取得・管理する。
///
/// gh に聞くのも (`GitHubClient`)、置き場を出し入れするのも (`AvatarCache`) 向こうの仕事で、
/// ここが持つのは「手元にあれば返し、無ければ gh から落とす」「失敗した相手のクールダウン」
/// 「いつ聞き直すかの間隔」。
public enum FetchOrganizationAvatar {
    /// 見出しに出すアイコンを1つ手に入れる。
    ///
    /// 手元にあればそれを返し、無ければ gh に聞いて落としてくる。
    ///
    /// - Returns: 画像ファイルの場所。手に入らなければ nil (呼ぶ側は代わりの絵を描く)
    public static func fetch(owner: String, host: String = "github.com") -> URL? {
        guard host == "github.com", !owner.isEmpty,
              let file = AvatarCache.file(for: owner) else { return nil }
        let age = AvatarCache.age(of: owner)

        // 期限内のものがあれば、それで済ませる
        if let age, age < maxAge { return file }
        // 少し前に失敗した相手には、しばらく聞きに行かない。取れない理由
        // (ネットワークが無い・組織が private) は次の描き直しでも変わらないことが多く、
        // 一覧を開くたびに gh が起きることになる
        guard !isCoolingDown(owner) else { return age == nil ? nil : file }

        // 資格情報が無いときは相手固有の失敗（10分クールダウン）にしない。
        // 可否の再確認間隔 (60秒) で速やかに復帰できるようにする
        guard CheckOrganizationAvailability.check() else {
            return age == nil ? nil : file
        }

        guard let url = GitHubClient.avatarURL(owner: owner, host: host),
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
    public static func discard(owner: String) {
        AvatarCache.discard(owner)
        clearFailure(owner)
    }

    /// 取り直すまでの間隔。組織のアイコンが差し替わっても1週間で追いつく
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// 取れなかった相手に聞き直すまでの間隔
    private static let retryInterval: TimeInterval = 10 * 60

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
    private static let lock = NSLock()
}
