import AppKit
import Combine
import CoreGraphics
import DesignSystem
import ItermBridge
import SwiftUI

/// パネル左端のドラッグリサイズ用ハンドル。
/// iTerm2 側のリサイズ操作と干渉しないよう、パネル外縁（左端）に配置する。
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
        // 左方向へのドラッグで幅を拡大、右方向で縮小
        let delta = initialMouseX - NSEvent.mouseLocation.x
        // 許容幅の範囲定義は Appearance に集約して設定画面と整合させる
        let range = Appearance.widthRange
        onResize?(max(range.lowerBound, min(range.upperBound, initialWidth + delta)))
    }

    override func mouseUp(with event: NSEvent) { dragging = false }
}

/// iTerm2 ウィンドウの左隣に吸着・追従するフローティングパネル。
///
/// CGWindowList により iTerm2 のウィンドウ枠を取得して位置合わせを行う
/// （オートメーション権限不要で動作可能）。
@MainActor
public final class SidebarPanel: NSObject {
    private var panel: NSPanel!
    private var handle: ResizeHandleView!
    private var backgroundTintView: NSView?
    private var timer: Timer?

    private let appearance: Appearance
    private var widthObserver: AnyCancellable?
    private var roomObserver: AnyCancellable?
    /// iTerm2 ウィンドウを右に寄せて表示領域を確保・復元する制御クラス
    private let room = SidebarRoom()

    private var lastTarget: NSRect = .zero
    /// 幅が最後に変更された時刻。ドラッグ操作中の不要な iTerm2 リサイズを抑制するために使用する
    private var lastWidthChange = Date.distantPast
    /// 幅変更完了とみなすまでの遅延時間（秒）。
    ///
    /// リサイズ中の頻繁な iTerm2 リサイズ要求とウィンドウマネージャの復元処理との競合を防ぐため、
    /// 操作が落ち着くまで iTerm2 の移動・リサイズを遅延させる。
    private let widthSettleDelay: TimeInterval = 0.35
    public private(set) var isShowing = false
    /// ユーザー操作により明示的に非表示にされたかどうかのフラグ（追従処理による自動再表示を抑止）
    public private(set) var userHidden = false

    private var width: CGFloat { appearance.sidebarWidth }

    /// ウィンドウ追従ポーリング間隔。移動中は約60fps（0.016秒）、静止時は省電力のため0.5秒に切り替える
    private var pollInterval: TimeInterval = 0.5
    private var stationaryCount = 0

    /// 表示状態の変更通知コールバック（非表示時のバックグラウンド処理抑制用）
    public var onVisibilityChange: ((Bool) -> Void)?

    public init(appearance: Appearance, content: some View) {
        self.appearance = appearance
        super.init()

        // 枠なし・影付きのフローティングパネル。
        // nonactivatingPanel を指定し、クリック時にも iTerm2 のフォーカスを奪わないようにする。
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
            self?.lastWidthChange = Date()
            // 望む幅が変わったのだから、諦めていた分は白紙に戻して試し直す
            self?.room.retryNow()
            self?.wakeUp()
        }
        // 設定解除時は即座に iTerm2 のリサイズを元の状態に復元する
        roomObserver = appearance.$makeRoomForSidebar.sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.wakeUp() } else { self.room.restore() }
        }
        appearance.onAppearanceChange = { [weak self] in
            self?.refreshBackground()
        }

        // iTerm2 がアクティブになった瞬間に即座に復帰したい
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appActivated),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)

        refreshBackground()
        updateLevel()
        schedule()
    }

    /// 背景色。iTerm2 のプロファイルから拾えたらそれを敷いて境目を消す
    public func applyBackground(_ color: NSColor?) {
        appearance.itermBackgroundColor = color
        refreshBackground()
    }

    private func refreshBackground() {
        let color = appearance.resolvedBackgroundColor
        backgroundTintView?.layer?.backgroundColor = color.cgColor
    }

    @objc private func appActivated() {
        updateLevel()
        wakeUp()
    }

    /// 前面アプリケーションに応じてパネルのウィンドウレベル（level）を更新する。
    ///
    /// iTerm2 または本アプリがアクティブな場合は端末の前面に表示するため .floating に設定し、
    /// 他のアプリがアクティブになった場合は作業の妨げにならないよう .normal に下げて背面に潜らせる。
    private func updateLevel() {
        // 前面アプリの特定に失敗した場合はちらつき防止のためレベル変更を行わない
        guard let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        else { return }
        let alongsideTerminal = front == ItermBridge.bundleID
            || front == Bundle.main.bundleIdentifier
        panel.level = alongsideTerminal ? .floating : .normal
    }

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

    /// iTerm2 のウィンドウ矩形取得（SidebarRoom と共通のロジックを使用）
    private func itermBounds() -> CGRect? { SidebarRoom.currentItermBounds() }

    /// iTerm2 の幅・位置調整を保留すべき状態かどうかを判定する。
    /// 幅変更操作中やマウスボタン押下中など、ユーザー操作中のウィンドウ移動競合を防ぐ。
    private var handsOff: Bool {
        if Date().timeIntervalSince(lastWidthChange) < widthSettleDelay { return true }
        return NSEvent.pressedMouseButtons != 0
    }

    private func updatePosition() {
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
            // 忘れるのは iTerm2 ごと終わったときだけ。CGWindowList は別スペースや
            // 隠した窓を返さないので、スペースを切り替えるたびに忘れていると
            // 寄せた分を戻せなくなる
            if !ItermBridge.isItermRunning { room.forget() }
            // iTerm2 が見つからない・隠れている間も 0.5 秒間隔で待つ
            pollInterval = 0.5
            return
        }

        // CGWindowList の原点はメイン画面左上、AppKit の原点はメイン画面左下のため、
        // 座標変換の基準高さにはメイン画面の高さを使用する
        guard let primary = NSScreen.screens.first else { return }
        // マルチディスプレイ環境で正しく配置・リサイズするため、対象ウィンドウが存在する画面を取得する
        let screen = SidebarRoom.screen(containing: bounds) ?? primary

        // 必要に応じて iTerm2 を右へ寄せてパネルの表示領域を確保する。
        // 移動・リサイズ直後はウィンドウ枠の再取得が必要なため次回ポーリングで配置する
        if appearance.makeRoomForSidebar, handsOff == false,
           room.makeRoom(itermBounds: bounds, screen: screen, width: width) {
            pollInterval = 0.016
            return
        }

        // CGWindowList（左上原点）から AppKit（左下原点）の座標系へ変換する。
        // メイン画面の左側に配置されたディスプレイ（x が負）にも追従できるよう、
        // 左端境界は 0 ではなく該当ディスプレイの visibleFrame.minX を下限とする
        // （Dock 等との重なりも防止）。
        let target = NSRect(x: max(screen.visibleFrame.minX, bounds.minX - width),
                            y: primary.frame.height - (bounds.minY + bounds.height),
                            width: width, height: bounds.height)

        if target != lastTarget {
            // 移動・リサイズ中は追従精度を高めるため更新頻度を上げる
            panel.setFrame(target, display: true, animate: false)
            lastTarget = target
            stationaryCount = 0
            pollInterval = 0.016
        } else {
            // 静止時はポーリング頻度を落として負荷を低減する
            stationaryCount += 1
            if stationaryCount > 10 { pollInterval = 0.5 }
        }

        if !isShowing {
            // 非表示期間中のアクティブ状態変化を反映するためレベルを再計算する
            updateLevel()
            panel.orderFront(nil)
            isShowing = true
            onVisibilityChange?(true)
        }
    }

    /// 寄せた分の iTerm2 の幅を元の状態に復元する
    public func restoreRoom() { room.restore() }

    public func toggle() {
        if isShowing {
            userHidden = true
            panel.orderOut(nil)
            isShowing = false
            onVisibilityChange?(false)
            // 非表示時は退避した表示領域を復元する
            room.restore()
        } else {
            userHidden = false
            // 次回追従時に即座に再配置させるため前回の矩形をリセット
            lastTarget = .zero
            wakeUp()
        }
    }
}
