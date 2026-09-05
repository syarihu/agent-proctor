import Foundation
import RepositoryGitHub

/// GitHub Organization でリポジトリをグループ化可能か（資格情報の有無）を判定する。
/// アイコンが取得できない環境では不要な見出し階層が増えるのを防ぐため、資格情報がない場合はグループ化を制限する。
///
/// 判定は資格情報の有無（`gh auth status` 等のローカル確認）のみを行い、トークンの有効性確認（ネットワークアクセス）までは行わない。
/// オフライン環境での起動時に表示レイアウトが変わるのを防ぐためである。
///
/// 判定結果はメモリ上にキャッシュする。ただし未ログイン（false）時は、後からログインされた場合に
/// アプリ再起動なしで検知できるよう 60 秒のインターバルで再試行する。
///
/// 並行アクセス時のデッドロックや過度な待機を防ぐため、資格情報確認処理の実行中はロックを解除する。
/// また、確認完了前に lastCheck を更新すると並行スレッドが未完了状態をキャッシュヒットと誤認して
/// 誤って false を返す（キャッシュスタンピード）恐れがあるため、確認完了後に状態を更新する。
public enum CheckOrganizationAvailability {
    /// 資格情報なしの結果をキャッシュする時間（秒）
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
