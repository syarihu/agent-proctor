import AppKit
import Foundation
import ProctorKit
import UserNotifications

/// macOS の通知センターへの窓口。
///
/// 何を知らせるかは決めない (それは `CollectNotices`)。ここがやるのは
/// 3つだけ。**許可を貰う・文面に組む・押されたら開く。**
///
/// 通知の identifier はセッションの id にしてある。macOS は同じ identifier の
/// 通知を差し替えるので、1つのセッションについて通知センターに残るのは
/// 常に最後の1件になる (確認待ち → 完了と続いても積み上がらない)。
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// 通知が押されたときに呼ばれる。渡すのはセッションの id
    var onOpen: ((String) -> Void)?

    /// 通知センターの許可の状態。オートメーションの許可と同じ並びにしてある
    enum Permission {
        case granted
        case denied
        /// まだ尋ねていない。ダイアログを出せるのはこのときだけ
        case undecided
        /// そもそも通知を出せない (バンドルの外で動いている)
        case unavailable
    }

    /// userInfo に入れる鍵。押されたときにどのセッションかを引くのに使う。
    /// 押されたことを受け取る口 (delegate) はメインの外から来るので nonisolated
    private nonisolated static let taskKey = "task"

    /// 通知センター。**バンドルの外では持たない。**
    ///
    /// `UNUserNotificationCenter.current()` はバンドルIDの無いプロセスから呼ぶと
    /// Objective-C の例外で落ちる (Swift 側では捕まえられない)。
    /// `swift run` で立ち上げたときがこれに当たるので、触る前に見分ける
    private let center: UNUserNotificationCenter?

    override init() {
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
    }

    /// 許可を求めて、決まった状態を返す。
    ///
    /// すでに決まっていれば、macOS はダイアログを出さずにその答えを返す。
    /// 断られたあとに呼んでも聞き直しにはならない (オートメーションと同じ)
    func requestAuthorization() async -> Permission {
        guard let center else { return .unavailable }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        return await permission()
    }

    /// 起動時に呼ぶ。答えは待たない。
    ///
    /// **最初の1件が出るときに尋ねるのでは間に合わない** — 許可を尋ねている間に
    /// 出した通知はどこにも残らず、いちばん知りたかった1件が黙って消える
    func requestAuthorizationIfNeeded() {
        Task { _ = await requestAuthorization() }
    }

    /// いまの許可の状態を読む。設定画面から呼ぶ
    func permission() async -> Permission {
        guard let center else { return .unavailable }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return .granted
        case .denied: return .denied
        case .notDetermined: return .undecided
        // ephemeral (App Clip) など、この先増えるものは決めつけない
        @unknown default: return .denied
        }
    }

    /// システム設定の通知のページを開く。断られたあとはここへ送るしかない
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /// 決まったものを配る。取り下げも同じ口で受ける
    func apply(_ changes: NoticeChanges) {
        guard let center, !changes.isEmpty else { return }
        if !changes.withdraw.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: changes.withdraw)
            // まだ配られていない分も下ろす。配るのは即時 (trigger が nil) なので
            // 普通は空だが、取り下げが追いついた瞬間に残っていると消し損ねる
            center.removePendingNotificationRequests(withIdentifiers: changes.withdraw)
        }
        for notice in changes.post {
            center.add(UNNotificationRequest(identifier: notice.taskID,
                                             content: content(for: notice),
                                             // trigger が nil ならすぐ出る
                                             trigger: nil))
        }
    }

    private func content(for notice: TaskNotice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        // 題は作業の名前。太字で出るところに、いちばん見分けの付くものを置く
        content.title = notice.name
        // 副題に「何が起きたか」と居場所。一覧の記号をそのまま使うので、
        // サイドバーで見慣れた ⏳ / ✅ / ✖ と字面が揃う
        content.subtitle = Localized.text(
            "app.notify.subtitle",
            "\(TaskStatus.mark(notice.status)) \(TaskStatus.label(notice.status))",
            notice.repoName, notice.branch)
        // 本文は「何を待っているか」。無いときは空にしておく。
        // 埋めるために状態をもう一度書くと、副題と同じ言葉が二度並ぶ
        content.body = notice.detail ?? ""
        content.sound = .default
        content.userInfo = [Notifier.taskKey: notice.taskID]
        // 同じセッションの通知は通知センターで1つにまとまる
        content.threadIdentifier = notice.taskID
        return content
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 押されたとき。一覧の行を押したときと同じところへ連れて行く
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo[Notifier.taskKey] as? String
        // 先に返しておく。タブを開くのは Apple Event の往復で、
        // 待たせている間ずっと通知センターが押されたままになる
        completionHandler()
        guard let id else { return }
        Task { @MainActor in self.onOpen?(id) }
    }

    /// 前面にいる間も出す。
    ///
    /// このアプリが前面なのは設定を開いているときくらいで、そこで黙られると
    /// 設定を触っている間だけ通知が消える (試している最中がいちばん困る)
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}
