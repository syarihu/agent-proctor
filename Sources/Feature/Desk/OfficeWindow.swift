import AppKit
import AppState
import DesignSystem
import Resources
import SwiftUI

/// 独立したオフィス（見取り図）ウィンドウのコントローラ。
///
/// メニューバー常駐アプリ（.accessory）のため、表示中は一時的に activationPolicy を .regular に昇格させ、
/// 閉じた際に他に開いているウィンドウが無ければ .accessory に戻す。
@MainActor
public final class OfficeWindow {
    /// アプリ終了処理中フラグ。通常クローズと終了時クローズを区別する
    public static var isTerminating = false
    private static let openStateKey = "OfficeWindow.isOpen"
    private static let frameAutosaveName = "OfficeWindow"

    /// 前回終了時にオフィスウィンドウが開いていたかどうか
    public static var wasOpenOnQuit: Bool {
        UserDefaults.standard.bool(forKey: openStateKey)
    }

    /// ウィンドウ開閉状態の保存
    public static func setOpenState(_ open: Bool) {
        UserDefaults.standard.set(open, forKey: openStateKey)
    }

    private var window: NSWindow?
    private let store: TaskStore
    private let appearance: Appearance
    private let onOpen: (String) -> Void

    public var onVisibilityChange: ((Bool) -> Void)?
    public var onClose: (() -> Void)?

    public var isVisible: Bool {
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    public init(store: TaskStore, appearance: Appearance, onOpen: @escaping (String) -> Void) {
        self.store = store
        self.appearance = appearance
        self.onOpen = onOpen
    }

    public func show() {
        if window == nil { window = make() }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        Self.setOpenState(true)
        onVisibilityChange?(true)
    }

    private func make() -> NSWindow {
        let view = OfficeView(store: store, appearance: appearance, onOpen: onOpen)
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = Localized.text("app.office.window_title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 580, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = delegateProxy

        // 保存されたウィンドウサイズ・位置があれば復元し、無ければ既定の 960x600 で画面中央に配置する
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.setContentSize(NSSize(width: 960, height: 600))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)

        return window
    }

    private lazy var delegateProxy = WindowDelegateProxy(
        onClose: { [weak self] in
            guard let self else { return }
            self.window?.saveFrame(usingName: Self.frameAutosaveName)
            // アプリ終了に伴うクローズでなければ、次回自動起動フラグを落とす
            if !Self.isTerminating {
                Self.setOpenState(false)
            }
            self.onVisibilityChange?(false)
            self.onClose?()
        },
        onVisibilityChange: { [weak self] visible in
            self?.onVisibilityChange?(visible)
        })

    private final class WindowDelegateProxy: NSObject, NSWindowDelegate {
        private let onClose: () -> Void
        private let onVisibilityChange: (Bool) -> Void

        init(onClose: @escaping () -> Void, onVisibilityChange: @escaping (Bool) -> Void) {
            self.onClose = onClose
            self.onVisibilityChange = onVisibilityChange
        }

        func windowWillClose(_ notification: Notification) { onClose() }
        func windowDidMiniaturize(_ notification: Notification) { onVisibilityChange(false) }
        func windowDidDeminiaturize(_ notification: Notification) { onVisibilityChange(true) }
    }
}

/// オフィスウィンドウのルート View。
private struct OfficeView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var appearance: Appearance
    let onOpen: (String) -> Void

    private var deskIslands: [DeskIsland] {
        DeskIslands.build(store: store, appearance: appearance)
    }

    var body: some View {
        DeskView(islands: deskIslands,
                 rateLimits: store.rateLimitSummaries,
                 running: store.collecting,
                 persistenceKey: "OfficeWindow",
                 onOpen: onOpen)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
