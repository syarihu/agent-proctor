import AppKit
import SwiftUI
import ProctorKit

/// アプリの組み立て。
///
/// 画面は2つだけ持つ。
///   - サイドバー … iTerm2 のウィンドウの左隣に吸着して一覧を出す
///   - メニューバー … 要約と、サイドバーの表示切替や終了の入口
///
/// Dock には出さない (LSUIElement)。端末に寄り添う道具なので、
/// 切り替え対象として並ぶと邪魔になる。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TaskStore!
    private var appearance: Appearance!
    private var sidebar: SidebarPanel!
    private var menuBar: MenuBarController!
    private var folding: RepoFolding!
    private var reaper: Reaper!
    private var focus: FocusWatcher!
    private var settings: SettingsWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Dock アイコンを出さない

        store = TaskStore()
        appearance = Appearance()
        folding = RepoFolding()
        let store = store!
        let appearance = appearance!
        let folding = folding!

        sidebar = SidebarPanel(
            appearance: appearance,
            content: TaskListView(store: store, appearance: appearance, folding: folding,
                                  onOpen: { [weak self] task in
                self?.open(taskID: task.id)
            }, onClose: { [weak self] task in
                self?.store.forget(id: task.id)
            }))
        sidebar.onVisibilityChange = { [weak self] visible in
            // 見えていない間は git を起動しない
            self?.store.setCollecting(visible)
        }

        settings = SettingsWindow(appearance: appearance)

        menuBar = MenuBarController(store: store)
        menuBar.onToggleSidebar = { [weak self] in self?.sidebar.toggle() }
        menuBar.isSidebarHidden = { [weak self] in self?.sidebar.userHidden ?? false }
        menuBar.onOpenTask = { [weak self] id in self?.open(taskID: id) }
        menuBar.onOpenSettings = { [weak self] in self?.settings.show() }

        reaper = Reaper { [weak self] in self?.store.refreshNow() }
        focus = FocusWatcher(
            onFocus: { [weak self] session in self?.store.setFocused(session) },
            // 書いたのは自分なので、台帳の更新時刻を待たずに映す
            onSeen: { [weak self] in self?.store.refreshNow() })

        // 背景色は iTerm2 が起きてウィンドウを持つまで取れない。
        // 一度取れれば十分なので、取れるまで少し粘る
        chaseBackground(remaining: 30)
    }

    /// 居場所を作るために詰めた iTerm2 の幅を返してから終わる。
    /// 返さずに消えると、なぜ端末が細いのか分からないまま残る。
    ///
    /// 片付けは willTerminate ではなくここでやる。あちらは畳み始めたあとに呼ばれるので、
    /// Apple Event の往復が間に合わずに戻せないことがある。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sidebar?.restoreRoom()
        return .terminateNow
    }

    /// 一覧の行を開く。
    ///
    /// そのセッションが今もタブで生きていればそのタブにフォーカスし、
    /// いなければ新しいタブで `proctor attach` を実行して会話の続きから開く。
    private func open(taskID: String) {
        // Store が持つ台帳から引き直す。数えた一覧 (tasks) は10秒ごとにしか
        // 更新されないので、押した瞬間に近い itermSession はこちらで見る
        guard let task = store.record(id: taskID) else { return }

        if let session = task.itermSession, ItermBridge.focus(sessionID: session) {
            return
        }
        // 押しても何も起きないと手掛かりが無くなるので、失敗は伝える
        if !ItermBridge.openTab(runningCommand: "proctor attach \(task.id)") {
            let alert = NSAlert()
            alert.messageText = "\(task.displayName) を開けませんでした"
            alert.informativeText = "iTerm2 が起動しているか、"
                + "オートメーションが許可されているか確かめてください。"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func chaseBackground(remaining: Int) {
        if let color = ItermBridge.backgroundColor() {
            sidebar.applyBackground(color)
            return
        }
        sidebar.applyBackground(nil)
        guard remaining > 0 else { return }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
            Task { @MainActor in self.chaseBackground(remaining: remaining - 1) }
        }
    }
}

// トップレベルのコードはメインスレッドで動くが、静的にはそう見えていないので
// 明示して @MainActor の AppDelegate を組み立てる
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
