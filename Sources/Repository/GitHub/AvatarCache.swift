import Foundation
import Utility

/// 取ってきたアイコンの置き場。ファイルの出し入れはここだけにする。
///
/// **いつ取り直すかは決めない。** それは「古いと見なすのは何日からか」という
/// 方針であって、置き場の仕事ではない (`FetchOrganizationAvatar` が決める)。
/// ここが答えるのは「どこに置くか」と「いつ書かれたか」まで。
public enum AvatarCache {
    /// その持ち主のアイコンを置く場所。まだ無くても場所は答える。
    /// **置き場の中を指せない名前なら nil** (理由は `fileName`)
    public static func file(for owner: String) -> URL? {
        let safe = String(owner.map { allowed.contains($0) ? $0 : "-" })
        guard !safe.isEmpty else { return nil }
        let url = Paths.avatarsDir.appendingPathComponent(safe)
        // 置き場の直下から出ていないことを確かめる。通す字を絞ってあるので
        // ここに引っかかることはないはずだが、**この URL は消す操作にも渡る**。
        // 外を指したまま `discard` に入ると台帳ごと消えるので、二重に見る。
        //
        // **URL どうしではなく path で比べる。** `appendingPathComponent` は
        // 実在するディレクトリにだけ末尾の "/" を付けるので、置き場をまだ
        // 作っていない初回は `avatars` と `avatars/` になって URL が食い違い、
        // **一枚も保存できなくなる**。`path` なら末尾の "/" は落ちる
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == Paths.avatarsDir.standardizedFileURL.path else { return nil }
        return url
    }

    /// 最後に書かれてからの時間。まだ無ければ nil
    public static func age(of owner: String) -> TimeInterval? {
        guard let path = file(for: owner)?.path else { return nil }
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// 手元の1枚を捨てる。読めなかったものを次に持ち越さないために使う
    public static func discard(_ owner: String) {
        guard let file = file(for: owner) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// ファイル名に通す字。GitHub の login が取りうる範囲 (英数字とハイフン) に、
    /// 念のため下線を足しただけ。**それ以外は落とす。**
    ///
    /// 持ち主の名前をそのままファイル名にできない理由が2つある。
    ///
    /// 1. `/` が入る書き方がある (GitLab の入れ子グループ)。そのままでは
    ///    置き場の下にディレクトリを掘ってしまう
    /// 2. **`.` や `..` は名前ではなく場所を指す。** `avatars/..` は台帳のある
    ///    ディレクトリそのもので、そこへ `discard` が走ると
    ///    `state.json` ごと消える。remote に `github.com/../x.git` と
    ///    書いてあるだけでそうなる
    ///
    /// 拡張子を付けないのは、**中身が PNG とは限らないから。** GitHub が返すのは
    /// アップロードされた画像そのもので、JPEG のことがある。`.png` と名乗らせると
    /// 名前が嘘をつく (読む側は中身で判別するので動きはする)
    private static let allowed = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
}
