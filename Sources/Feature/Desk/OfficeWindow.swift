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
        // 仕舞われている窓は前へ出すだけでは戻らない。
        // ホットキーを押したのに Dock で跳ねるだけ、という見え方になる
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        // アプリを前に出さずに窓だけ前へ出す。
        //
        // `NSApp.activate` で自分を前面に持ってくると、Stage Manager はそれを
        // アプリの切り替えとして扱い、いま見ていたステージを押しのける。
        // 見取り図は覗きに来るものなので、覗いた先を片付けてしまっては困る。
        // 窓が非アクティブ化パネルなのも同じ理由で、`orderFrontRegardless` は
        // アプリが前にいなくてもその窓を同じ階層の一番上へ出す
        window?.orderFrontRegardless()
        Self.setOpenState(true)
        onVisibilityChange?(true)
    }

    /// 窓を引っ込める。ホットキーをもう一度押したときと、別のアプリへ移ったときに通る。
    ///
    /// 閉じる (`close`) のではなく退ける (`orderOut`) のは、次に出すときへ
    /// 大きさと位置をそのまま残すため。`windowWillClose` も飛ばないので、
    /// 見えなくなったことはここから自分で知らせる
    public func hide() {
        guard let window, window.isVisible else { return }
        window.saveFrame(usingName: Self.frameAutosaveName)
        window.orderOut(nil)
        onVisibilityChange?(false)
        onClose?()
    }

    /// ホットキーの1押しぶん。出ていれば引っ込める、出ていなければ出す。
    ///
    /// 前面にいるかどうかは見ない。この窓は iTerm2 が前に出ても退かずに下に残るので、
    /// 「出ているが手前ではない」が普段の状態になる。そこで前面に出すほうを選ぶと、
    /// 端末で手を動かしたあと片付けるのに2回押すことになる
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    private func make() -> NSWindow {
        let view = OfficeView(store: store, appearance: appearance, onOpen: onOpen)
        let hosting = NSHostingController(rootView: view)
        // 普通のウィンドウではなくパネル。
        //
        // `nonactivatingPanel` は、押しても掴んでもアプリを前面に引き出さない窓。
        // iTerm2 の hotkey window と同じ作りで、これがサイドバーにも使われている。
        // ここでアプリごと前に出ると、Stage Manager が見ていたステージを畳んでしまう。
        // 中身は SpriteKit が生のマウスイベントを直に受けるので、
        // アプリが前にいなくても机は押せるし、床は掴んで動かせる
        let window = NSPanel(contentViewController: hosting)
        window.title = Localized.text("app.office.window_title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .nonactivatingPanel]
        // 普通のウィンドウより1段だけ高いところに置く。
        //
        // 同じ高さに置くと、前に出たアプリが自分のウィンドウを持ち上げた時点でその後ろに埋まる。
        // iTerm2 を引っ込めた拍子にこの窓が消えたように見えるのは、消えているのではなく、
        // 前面を返されたアプリの後ろへ回っているため。覗きに来た床が覗いた先に隠れては困る。
        //
        // 浮かせきらない (`.floating`) のは、iTerm2 の hotkey window に上を取らせるため。
        // あちらは浮く設定なので、1段の差があれば重なる順は狙いどおりになる
        window.isFloatingPanel = false
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        // Stage Manager に「この窓は集合に加わらない」と伝える。
        // 加わると、覗きに来ただけの窓が相手のステージの一員になってしまう
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .auxiliary]
        window.minSize = NSSize(width: 580, height: 400)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
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
                 style: .suites,
                 onOpen: onOpen)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
