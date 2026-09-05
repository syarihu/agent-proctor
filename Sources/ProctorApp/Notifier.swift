import AppKit
import FeatureSettings
import Foundation
import Model
import Resources
import UserNotifications

/// macOS 通知センターとの連携クラス。通知権限のリクエスト、通知の投稿・取り下げ、クリック時のハンドリングを行う。
/// 同一セッションの通知は同一 identifier を使用して上書きし、通知センターへの重複蓄積を防ぐ。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate, NotificationPermissionAuthorizer {
    /// 通知が押されたときに呼ばれる。渡すのはセッションの id
    var onOpen: ((String) -> Void)?

    typealias Permission = NotificationPermissionStatus

    /// 通知タップ時にタスクを特定するための userInfo キー
    private nonisolated static let taskKey = "task"

    /// 通知センターインスタンス。swift run などバンドル ID を持たないプロセスでのクラッシュを防ぐため nil 許容とする
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
    }

    /// 通知権限を要求し、現在の状態を返す
    func requestAuthorization() async -> Permission {
        guard let center else { return .unavailable }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    /// 初回起動時に非同期で通知権限を要求する
    func requestAuthorizationIfNeeded() {
        Task { _ = await requestAuthorization() }
    }

    /// 現在の通知権限ステータスを取得する
    func permission() async -> Permission {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        case .notDetermined: return .undecided
        @unknown default: return .denied
        }
    }

    /// システム設定の通知画面を開く
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    func openSettings() {
        Self.openSettings()
    }

    /// 通知の投稿および取り下げを適用する
    func apply(_ changes: NoticeChanges) {
        guard let center, !changes.isEmpty else { return }
        if !changes.withdraw.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: changes.withdraw)
            // 配信待ち（pending）のリクエストも確実に削除する
            center.removePendingNotificationRequests(withIdentifiers: changes.withdraw)
        }
        for notice in changes.post {
            center.add(UNNotificationRequest(identifier: notice.taskID,
                                             content: content(for: notice),
                                             trigger: nil))
        }
    }

    private func content(for notice: TaskNotice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        // タイトルにタスク表示名を設定する
        content.title = notice.name
        // サブタイトルに状態マーク・ラベル・リポジトリ・ブランチ情報を設定する
        content.subtitle = Localized.text(
            "app.notify.subtitle",
            "\(TaskStatus.mark(notice.status)) \(TaskStatus.label(notice.status))",
            notice.repoName, notice.branch)
        // 本文に詳細情報（承認要求内容等）を設定する
        content.body = notice.detail ?? ""
        content.sound = .default
        content.userInfo = [Notifier.taskKey: notice.taskID]
        // 同一セッションの通知をグループ化する
        content.threadIdentifier = notice.taskID
        return content
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 通知クリック時のハンドラ
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo[Notifier.taskKey] as? String
        // タブ移動（AppleScript）完了待ちによる通知センターの応答遅延を防ぐため、先に完了ハンドラを呼ぶ
        completionHandler()
        guard let id else { return }
        Task { @MainActor in self.onOpen?(id) }
    }

    /// アプリがフォアグラウンドの場合もバナーとサウンドを表示する
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
