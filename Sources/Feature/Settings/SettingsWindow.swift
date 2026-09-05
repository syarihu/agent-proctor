import AppKit
import DesignSystem
import Resources
import SwiftUI

/// 設定画面のウィンドウコントローラ。
///
/// LSUIElement（Dock アイコン非表示）アプリのため、表示時に一時的に activationPolicy を .regular に昇格させ、
/// 閉じた際に .accessory に戻す。
@MainActor
public final class SettingsWindow {
    private var window: NSWindow?
    private let appearance: Appearance
    private let notices: NoticeSettings
    private let notifier: NotificationPermissionAuthorizer

    public init(appearance: Appearance, notices: NoticeSettings,
                notifier: NotificationPermissionAuthorizer) {
        self.appearance = appearance
        self.notices = notices
        self.notifier = notifier
    }

    public func show() {
        if window == nil { window = make() }
        // accessory のままだとキーウィンドウになれないため、表示中のみ regular に切り替える
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.center()
    }

    private func make() -> NSWindow {
        let hosting = NSHostingController(
            rootView: SettingsView(appearance: appearance, notices: notices,
                                   notifier: notifier))
        let window = NSWindow(contentViewController: hosting)
        window.title = Localized.text("app.settings.window_title")
        window.styleMask = [.titled, .closable]
        // 再オープン時に再利用するためウィンドウを破棄しない
        window.isReleasedWhenClosed = false
        window.delegate = closeWatcher
        return window
    }

    /// ウィンドウクローズ時に activationPolicy を .accessory に戻す
    private lazy var closeWatcher = CloseWatcher {
        NSApp.setActivationPolicy(.accessory)
    }

    private final class CloseWatcher: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}
