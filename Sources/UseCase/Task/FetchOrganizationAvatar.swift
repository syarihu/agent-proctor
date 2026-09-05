import Foundation
import RepositoryGitHub
import Utility

/// Organization のアバターアイコンを取得・キャッシュ管理する。
/// ローカルキャッシュが存在すれば返し、存在しない場合は GitHub からダウンロードする。
/// 失敗時のクールダウンや再取得間隔の制御を担う。
public enum FetchOrganizationAvatar {
    /// 指定されたオーナーのアバター画像ファイル URL を取得する。
    /// - Returns: 画像ファイルのローカル URL。取得できない場合は nil
    public static func fetch(owner: String, host: String = "github.com") -> URL? {
        guard host == "github.com", !owner.isEmpty,
              let file = AvatarCache.file(for: owner) else { return nil }
        let age = AvatarCache.age(of: owner)

        if let age, age < maxAge { return file }
        // 連続した外部コマンド実行・ネットワークアクセスを防ぐため、失敗直後はクールダウン期間を設ける
        guard !isCoolingDown(owner) else { return age == nil ? nil : file }

        // 資格情報がない場合は個別エラー扱いにせず、全体の再確認間隔 (60秒) に委ねる
        guard CheckOrganizationAvailability.check() else {
            return age == nil ? nil : file
        }

        guard let url = GitHubClient.avatarURL(owner: owner, host: host),
              GitHubClient.downloadAvatar(from: url, to: file) else {
            noteFailure(owner)
            // 再取得に失敗しても古いキャッシュが存在する場合はそれを優先して返し、表示のチラつきを防ぐ
            return age == nil ? nil : file
        }
        clearFailure(owner)
        return file
    }

    /// キャッシュされたアイコンファイルを破棄する（画像読み込み失敗時に呼び出し）。
    /// 失敗記録も同時にクリアし、次回の即時再取得を可能にする。
    public static func discard(owner: String) {
        AvatarCache.discard(owner)
        clearFailure(owner)
    }

    /// キャッシュの有効期間（7日間）
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    /// 取得失敗時の再試行クールダウン時間（10分）
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
