import AppKit
import ProctorKit
import SwiftUI

/// 設定画面の器。
///
/// Dock に出さないアプリ (LSUIElement) なので、ウィンドウを出すだけでは前に来ない。
/// 明示的にアプリごと有効にしてから前面に持ってくる。
///
/// 器は1つだけ持ち回す。開くたびに作ると、閉じずに何枚も重なる。
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let appearance: Appearance
    private let notices: NoticeSettings
    private let notifier: Notifier

    init(appearance: Appearance, notices: NoticeSettings, notifier: Notifier) {
        self.appearance = appearance
        self.notices = notices
        self.notifier = notifier
    }

    func show() {
        if window == nil { window = make() }
        // 通常は accessory (Dock に出さない) なので、そのままだとキーウィンドウに
        // なれない。設定を触っている間だけ regular に上げて、閉じたら戻す
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
        // 閉じても捨てない。次に開くときに作り直さずに済む
        window.isReleasedWhenClosed = false
        window.delegate = closeWatcher
        return window
    }

    /// 閉じたら Dock から引っ込める。
    /// 設定を見ている間だけ普通のアプリとして振る舞わせたい
    private lazy var closeWatcher = CloseWatcher {
        NSApp.setActivationPolicy(.accessory)
    }

    private final class CloseWatcher: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) { onClose() }
    }
}
