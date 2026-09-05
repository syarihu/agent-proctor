import Foundation

/// 通知センターの許可の状態。
public enum NotificationPermissionStatus: Sendable {
    case granted
    case denied
    /// まだ尋ねていない。ダイアログを出せるのはこのときだけ
    case undecided
    /// そもそも通知を出せない (バンドルの外で動いている)
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
