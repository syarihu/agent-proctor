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
    private var roomObserver: AnyCancellable?
    /// iTerm2 を右へ寄せて居場所を作る係。寄せた分を戻すのもここが覚えている
    private let room = SidebarRoom()

    private var lastTarget: NSRect = .zero
    /// 幅が最後に変わった時刻。ドラッグやスライダーで動かしている間は
    /// 端末の幅を触らずに待つ (下記 widthSettleDelay)
    private var lastWidthChange = Date.distantPast
    /// 幅が落ち着いたと見なすまでの間。
    ///
    /// 幅を変えるたびに iTerm2 をリサイズすると、ドラッグ中に何度も窓を動かすことになり、
    /// iTerm2 やウィンドウマネージャが元の大きさへ戻しにかかって取っ組み合いになる。
    /// サイドバー自身は即座に追従するので、待つのは端末を詰める分だけ
    private let widthSettleDelay: TimeInterval = 0.35
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

        // 枠なし・影付きのフローティングパネル。
        // nonactivatingPanel なので、触っても iTerm2 からフォーカスを奪わない。
        // 高さ (level) は前面のアプリに合わせて updateLevel が動かす
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
        // 設定で切られたら、寄せた分はその場で返す。
        // 切ったのに端末が細いままだと、何が起きたのか分からない
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
    func applyBackground(_ color: NSColor?) {
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

    /// パネルの高さ (level) を前面のアプリで決める。
    ///
    /// 端末の脇に居る間は端末より上に居てほしいので浮かせる。**別のアプリに
    /// 移ったあとまで浮かせたままにしない。** 切り替えた先のウィンドウの上に
    /// 居座って、関係の無い作業の邪魔をするため。普通の高さまで下げれば、
    /// 重なるウィンドウの下に潜り、重ならなければ見えたまま残る。
    ///
    /// ステージマネージャーではこれが問題にならなかった。アプリを移ると
    /// iTerm2 のウィンドウごと画面から外れ、追う相手を失ったパネルが
    /// そのまま引っ込んでいたため。切っていると窓は画面に残るので、
    /// 浮いたままのパネルだけが上に出てしまう。
    ///
    /// 自分が前面のときも浮かせるのは、**サイドバーを押した瞬間に前面が
    /// こちらへ移る**から。ここで下げると指の下でパネルが沈む。
    private func updateLevel() {
        // 誰が前面か分からないときは触らない。読めなかっただけで
        // 上げ下げすると、パネルがちらつく
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

    /// iTerm2 のウィンドウ枠。読み方は SidebarRoom と共通にしてある
    /// (別々に持つと、追いかける窓と寄せる窓が食い違う)
    private func itermBounds() -> CGRect? { SidebarRoom.currentItermBounds() }

    /// いま端末の幅を触ってはいけないか。
    ///
    /// - 幅を変えている途中 (端のドラッグ・設定のスライダー)
    /// - マウスのボタンを押している間 (窓や縁を掴んでいる可能性がある)
    ///
    /// どちらも「人が手を動かしている最中」で、そこへ割り込んで窓を動かすと
    /// 掴んでいるものが飛ぶ。落ち着いてから1回だけ寄せれば足りる
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

        // 座標を入れ替える基準はメイン画面。CGWindowList の原点は
        // 「メイン画面の左上」、AppKit の原点は「メイン画面の左下」なので、
        // どの画面に乗っている窓でも、引き算に使う高さはメイン画面のものになる
        guard let primary = NSScreen.screens.first else { return }
        // 寄せるのも置くのも、**その窓が乗っている画面**を基準にする。
        // メイン画面で決め打ちにすると、別の画面に出した端末では左端も高さも
        // 別物を見ることになり、場所を空け損ねたうえにサイドバーが画面の外へ出る
        let screen = SidebarRoom.screen(containing: bounds) ?? primary

        // 左に隙間が無ければ iTerm2 を右へ寄せて場所を作る。
        // 動かせたなら枠が変わっているので、置くのは次の周回で読み直してから。
        //
        // 手が動いている間は待つ。幅のドラッグ中やマウスを押している間に
        // 端末を動かすと、掴んでいる窓が手の中で飛んだり、iTerm2 側の
        // 引き戻しとぶつかって全画面へ戻されたりする
        if appearance.makeRoomForSidebar, handsOff == false,
           room.makeRoom(itermBounds: bounds, screen: screen, width: width) {
            pollInterval = 0.016
            return
        }

        // CGWindowList の原点は画面の左上、AppKit は左下。ここで入れ替える。
        // 左端で止めるのはその画面の縁であって 0 ではない。0 で止めると、
        // メイン画面より左に置いた画面 (枠の x が負になる) の端末に付いていけない。
        // 縁を visibleFrame で測るのは makeRoom と揃えるため。Dock が左にあるとき、
        // frame で測ると場所を空けられなかった場合に Dock の下へ潜り込む
        let target = NSRect(x: max(screen.visibleFrame.minX, bounds.minX - width),
                            y: primary.frame.height - (bounds.minY + bounds.height),
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
            // 出し直すときは高さも決め直す。隠れている間にアプリを移られると
            // アクティブになった知らせを取り逃がしている
            updateLevel()
            panel.orderFront(nil)
            isShowing = true
            onVisibilityChange?(true)
        }
    }

    /// 寄せた分の iTerm2 の幅を返す。終了するときに呼ぶ
    func restoreRoom() { room.restore() }

    func toggle() {
        if isShowing {
            userHidden = true
            panel.orderOut(nil)
            isShowing = false
            onVisibilityChange?(false)
            // 隠したなら場所を空けておく理由が無い。詰めた分を返す
            room.restore()
        } else {
            userHidden = false
            // 次の追従で必ず置き直させる
            lastTarget = .zero
            wakeUp()
        }
    }
}
