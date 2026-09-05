import Foundation
import Utility

/// 取得したアバター画像のローカルキャッシュ管理。
///
/// 保存先の解決と更新日時の取得のみを責務とし、キャッシュ有効期限の判断は上位層が行う。
public enum AvatarCache {
    /// 指定オーナーのアバターファイル保存先 URL。不正なパスになる場合は nil。
    public static func file(for owner: String) -> URL? {
        let safe = String(owner.map { allowed.contains($0) ? $0 : "-" })
        guard !safe.isEmpty else { return nil }
        let url = Paths.avatarsDir.appendingPathComponent(safe)
        // ディレクトリトラバーサル防止のため、キャッシュディレクトリ配下に収まっているかをパス文字列で検証する
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == Paths.avatarsDir.standardizedFileURL.path else { return nil }
        return url
    }

    /// キャッシュファイルの最終更新からの経過時間（秒）。ファイルが存在しない場合は nil。
    public static func age(of owner: String) -> TimeInterval? {
        guard let path = file(for: owner)?.path else { return nil }
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// キャッシュファイルを破棄する。
    public static func discard(_ owner: String) {
        guard let file = file(for: owner) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// ファイル名として許可する文字種。
    /// ディレクトリトラバーサルや不正な階層作成（"/" や ".." など）を防止するためホワイトリストで制限する。
    /// また、画像フォーマットが PNG / JPEG 等で異なるため拡張子は固定しない。
    private static let allowed = Set(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
}
