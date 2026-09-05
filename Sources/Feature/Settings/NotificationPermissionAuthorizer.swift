import Foundation

/// 通知センターの権限状態。
public enum NotificationPermissionStatus: Sendable {
    case granted
    case denied
    /// 未確認状態（システムダイアログを表示可能な状態）
    case undecided
    /// 通知利用不可（アプリバンドル外での実行時など）
    case unavailable
}

/// 通知の許可状態を取得・要求するプロトコル。
/// 設定画面 (FeatureSettings) から通知実装 (Notifier) を疎結合にするために用いる。
@MainActor
public protocol NotificationPermissionAuthorizer: AnyObject {
    func requestAuthorization() async -> NotificationPermissionStatus
    func permission() async -> NotificationPermissionStatus
    func openSettings()
}
