import AppKit
import SwiftUI
import CoreGraphics
import Combine

/// 左端でドラッグして幅を変えるための取っ手。
///
/// 幅 8px。iTerm2 側のリサイズと干渉しないよう、内側ではなく外側の縁に置く。
final class ResizeHandleView: NSView {
    var onResize: ((CGFloat) -> Void)?
    private var initialMouseX: CGFloat = 0
    private var initialWidth: CGFloat = 0
    private var dragging = false

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        initialMouseX = NSEvent.mouseLocation.x
        initialWidth = window?.frame.width ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging else { return }
        // 左端を外側 (左) にドラッグすると幅が広がり、内側 (右) だと狭まる
        let delta = initialMouseX - NSEvent.mouseLocation.x
        // 範囲は Appearance が持つ。ここに数字を書くと設定画面とずれる
        let range = Appearance.widthRange
        onResize?(max(range.lowerBound, min(range.upperBound, initialWidth + delta)))
    }

    override func mouseUp(with event: NSEvent) { dragging = false }
}

/// iTerm2 のウィンドウの左隣に吸着して追従するパネル。
///
/// 位置合わせは CGWindowList で iTerm2 のウィンドウ枠を読んで行う。
/// AppleScript と違ってオートメーションの許可が要らないので、
/// 許可を出す前でも吸着だけは動く。
@MainActor
final class SidebarPanel: NSObject {
    private var panel: NSPanel!
    private var handle: ResizeHandleView!
    private var backgroundTintView: NSView?
    private var timer: Timer?

    private let appearance: Appearance
    private var widthObserver: AnyCancellable?

    private var lastTarget: NSRect = .zero
    private(set) var isShowing = false
    /// メニューから手で閉じたかどうか。iTerm2 の追従が勝手に開き直さないための札
    private(set) var userHidden = false

    /// 幅の正本は Appearance。設定画面からも端のドラッグからも同じ値を動かす
    private var width: CGFloat { appearance.sidebarWidth }

    /// 追従の細かさ。動いている間は 60fps、止まったら 0.5 秒に落として省電力化する
    private var pollInterval: TimeInterval = 0.5
    private var stationaryCount = 0

    /// 見えているかどうかが変わったときに知らせる。
    /// 見えていない間は git を起動したくないので、集計の入切に使う
    var onVisibilityChange: ((Bool) -> Void)?

    init(appearance: Appearance, content: some View) {
        self.appearance = appearance
        super.init()

        // 枠なし・最前面・影付きのフローティングパネル。
        // nonactivatingPanel なので、触っても iTerm2 からフォーカスを奪わない
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        container.wantsLayer = true
        container.layer?.cornerRadius = 10
        container.layer?.masksToBounds = true

        let effect = NSVisualEffectView(frame: container.bounds)
        effect.autoresizingMask = [.width, .height]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        container.addSubview(effect)

        let tintView = NSView(frame: container.bounds)
        tintView.autoresizingMask = [.width, .height]
        tintView.wantsLayer = true
        container.addSubview(tintView)
        backgroundTintView = tintView

        let host = NSHostingView(rootView: content)
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)

        handle = ResizeHandleView(frame: NSRect(x: 0, y: 0, width: 8,
                                                height: container.bounds.height))
        handle.autoresizingMask = [.maxXMargin, .height]
        handle.onResize = { [weak self] newWidth in
            self?.appearance.sidebarWidth = newWidth
        }
        container.addSubview(handle)
        panel.contentView = container

        // 幅や背景色の変更を監視。どちらから変わっても即座に置き直す
        widthObserver = appearance.$sidebarWidth.sink { [weak self] _ in
            self?.wakeUp()
        }
        appearance.onAppearanceChange = { [weak self] in
            self?.refreshBackground()
        }

        // iTerm2 がアクティブになった瞬間に即座に復帰したい
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        refreshBackground()
        schedule()
    }

    /// 背景色。iTerm2 のプロファイルから拾えたらそれを敷いて境目を消す
    func applyBackground(_ color: NSColor?) {
        appearance.itermBackgroundColor = color
        refreshBackground()
    }

    private func refreshBackground() {
        let color = appearance.resolvedBackgroundColor
        backgroundTintView?.layer?.backgroundColor = color.cgColor
    }

    @objc private func appActivated() { wakeUp() }

    private func wakeUp() {
        stationaryCount = 0
        pollInterval = 0.016
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: false) {
            [weak self] _ in
            Task { @MainActor in
                self?.updatePosition()
                self?.schedule()
            }
        }
    }

    /// iTerm2 のウィンドウ枠を CGWindowList から読む。
    ///
    /// ステージマネージャで縮んだサムネイルを掴まないよう、
    /// 通常のメインステージにある大きさのものだけ対象にする。
    private func itermBounds() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for window in list {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            guard owner == "iTerm2", layer == 0,
                  let box = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let width = box["Width"] ?? 0
            let height = box["Height"] ?? 0
            if width >= 400 && height >= 300 {
                return CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0,
                              width: width, height: height)
            }
        }
        return nil
    }

    private func updatePosition() {
        guard let screen = NSScreen.screens.first else { return }
        let screenHeight = screen.frame.height

        // 手で閉じている間は場所も追わない。次に開いたときに合わせ直す
        guard !userHidden else {
            pollInterval = 0.5
            return
        }

        guard let bounds = itermBounds() else {
            if isShowing {
                panel.orderOut(nil)
                isShowing = false
                onVisibilityChange?(false)
            }
            // iTerm2 が見つからない・隠れている間も 0.5 秒間隔で待つ
            pollInterval = 0.5
            return
        }

        // CGWindowList の原点は画面の左上、AppKit は左下。ここで入れ替える
        let target = NSRect(x: max(0, bounds.minX - width),
                            y: screenHeight - (bounds.minY + bounds.height),
                            width: width, height: bounds.height)

        if target != lastTarget {
            // ドラッグ/リサイズ中。滑らかに追いかけたいので細かく回す
            panel.setFrame(target, display: true, animate: false)
            lastTarget = target
            stationaryCount = 0
            pollInterval = 0.016
        } else {
            // 止まっている。間隔を落として電池を使わない
            stationaryCount += 1
            if stationaryCount > 10 { pollInterval = 0.5 }
        }

        if !isShowing {
            panel.orderFront(nil)
            isShowing = true
            onVisibilityChange?(true)
        }
    }

    func toggle() {
        if isShowing {
            userHidden = true
            panel.orderOut(nil)
            isShowing = false
            onVisibilityChange?(false)
        } else {
            userHidden = false
            // 次の追従で必ず置き直させる
            lastTarget = .zero
            wakeUp()
        }
    }
}
