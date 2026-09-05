import AppKit
import AppState
import Combine
import DesignSystem
import FeatureMenuBar
import FeatureSettings
import FeatureSidebar
import ItermBridge
import Model
import Resources
import SwiftUI
import UseCaseNotice
import UseCaseSession
import UseCaseTask
import Utility

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
    private var folding: GroupFolding!
    private var avatars: OrgAvatarStore!
    private var pullRequests: PullRequestStore!
    private var reaper: Reaper!
    private var approvals: ApprovalWatcher!
    private var focus: FocusWatcher!
    private var settings: SettingsWindow!
    private var notices: NoticeSettings!
    private var notifier: Notifier!
    private var noticeWatcher: NoticeWatcher!
    /// 「変更を数える」の切り替えを見張る札。手放すと購読ごと切れる
    private var countObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Dock アイコンを出さない

        Appearance.checkOrganizationAvailability = {
            OrganizationGrouping.isAvailable()
        }

        store = TaskStore()
        appearance = Appearance()
        folding = GroupFolding()
        avatars = OrgAvatarStore()
        pullRequests = PullRequestStore()
        let store = store!
        let appearance = appearance!
        let folding = folding!
        let avatars = avatars!
        let pullRequests = pullRequests!

        // 数えるかどうかは設定を持っている側にしか分からないので、聞かせる。
        // **覚え込ませずに毎回聞く** — 途中で切り替えても次の数え直しから効く
        store.wantsDiff = { [weak appearance] in appearance?.countChanges ?? true }
        // 切り替えた瞬間に映す。次の周期を待たせると、オンに戻したのに
        // 数字が出ない時間ができて、設定が効かなかったように見える
        // (専用の入口を呼ぶ理由は TaskStore.countingSettingChanged)。
        //
        // **@Published の publisher は willSet で発火する。** つまりこの中から
        // appearance.countChanges を読むと、まだ切り替える前の値が返る。
        // TaskStore は数え直しを始めるときに wantsDiff() で設定を読み直すので、
        // 同期で呼ぶと**切り替える前の設定でまるごと1回数えてしまう**。
        //
        // 待つ長さはスイッチが動き終わるまで
        // (あの入口を通ると数え直しがメインスレッドを掴む。理由は向こうに書いた)。
        // debounce なのは、往復させたときに最後の1回しか走らせないため
        countObserver = appearance.$countChanges
            // 購読した瞬間にも現在値が流れてくる。起動時に数え直す用は無い
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak store] _ in store?.countingSettingChanged() }

        sidebar = SidebarPanel(
            appearance: appearance,
            content: TaskListView(store: store, appearance: appearance, folding: folding,
                                  avatars: avatars,
                                  pullRequests: pullRequests,
                                  onOpen: { [weak self] task in
                self?.open(taskID: task.id)
            }, onClose: { [weak self] task in
                self?.store.forget(id: task.id)
            }, onOpenWorktree: { [weak self] worktree in
                self?.open(worktree: worktree)
            }, onNewTab: { [weak self] path, name in
                self?.open(path: path, name: name, reusingTab: false)
            }, onClearAttention: { [weak self] tasks in
                self?.store.clearAttention(ids: tasks.map(\.id))
            }))
        sidebar.onVisibilityChange = { [weak self] visible in
            // 見えていない間は git を起動しない
            self?.store.setCollecting(visible)
            // gh も同じ。誰も見ていない番号のために問い合わせを出さない
            self?.pullRequests.setEnabled(visible)
        }

        notices = NoticeSettings()
        notifier = Notifier()
        notifier.onOpen = { [weak self] id in self?.open(taskID: id) }
        // 何も出さない設定なら尋ねない。使わない許可を求めるダイアログは、
        // 何を聞かれているのか分からないまま断られる
        if !notices.wanted.isEmpty { notifier.requestAuthorizationIfNeeded() }
        noticeWatcher = NoticeWatcher(store: store, settings: notices, notifier: notifier)

        settings = SettingsWindow(appearance: appearance, notices: notices,
                                  notifier: notifier)

        menuBar = MenuBarController(store: store)
        menuBar.onToggleSidebar = { [weak self] in self?.sidebar.toggle() }
        menuBar.isSidebarHidden = { [weak self] in self?.sidebar.userHidden ?? false }
        menuBar.onOpenTask = { [weak self] id in self?.open(taskID: id) }
        menuBar.onOpenSettings = { [weak self] in self?.settings.show() }

        reaper = Reaper { [weak self] in self?.store.refreshNow() }
        // agy の許可待ちだけはフックが運んでこないので、こちらから見に行く
        // (理由は ApprovalWatcher)。書いたのは自分なので、台帳の更新時刻を待たずに映す
        approvals = ApprovalWatcher(store: store) { [weak self] in self?.store.refreshNow() }
        focus = FocusWatcher(
            onFocus: { [weak self] session in self?.store.setFocused(session) },
            // エージェントが動いていない場所も一覧に混ぜたいので、現在地も預ける
            onDirectory: { [weak self] path in self?.store.setCurrentDirectory(path) },
            // タブ番号は端末に聞かないと分からないので、こちらも預ける。
            // 出さない設定のときは聞きに行かせない (問い合わせが1件減る)
            wantsTabNumbers: { [weak self] in self?.appearance.showTabNumbers ?? false },
            onTabNumbers: { [weak self] numbers in self?.store.setTabNumbers(numbers) },
            // 未読を降ろす合図。設定は途中で変わるので、覚え込ませずに毎回聞かせる
            seenPolicy: { [weak self] in self?.notices.seenPolicy ?? .onOpen },
            // 書いたのは自分なので、台帳の更新時刻を待たずに映す
            onSeen: { [weak self] in self?.store.refreshNow() })

        // **許可の答えが出るのを待ってから iTerm2 に話しかける。**
        // 未決のまま Apple Event を投げると、同意ダイアログが出ている間
        // メインスレッドが止まり、ここから先が何も描かれない (詳しくは
        // ItermBridge.permissionSettled)。尋ねるのは裏に回るので、
        // 立ち上がりはここで一旦 macOS に返る
        Task { @MainActor in
            await ItermBridge.settlePermission()
            // 背景色は iTerm2 が起きてウィンドウを持つまで取れない。
            // 一度取れれば十分なので、取れるまで少し粘る
            self.chaseBackground(remaining: 30)
        }
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
        // Store が持つ台帳から引き直す。数えた一覧 (tasks) は10秒かそれ以上の
        // 間隔でしか更新されないので、押した瞬間に近い itermSession はこちらで見る
        guard let task = store.record(id: taskID) else { return }

        // **押されたのなら、許可の答えが出るまで待ってから開く。**
        // 未決の間 ItermBridge は何も投げない (理由は permissionSettled) ので、
        // 待たずに進むと、まだ何も試していないのに「開けませんでした」と言うことになる
        Task { @MainActor in
            await ItermBridge.settlePermission()

            if let session = task.itermSession, ItermBridge.focus(sessionID: session) {
                return
            }
            // 押しても何も起きないと手掛かりが無くなるので、失敗は伝える
            if !ItermBridge.openTab(runningCommand: "proctor attach \(task.id)") {
                let alert = NSAlert()
                alert.messageText = Localized.text("app.alert.open_failed.title",
                                                   task.displayName)
                alert.informativeText = Localized.text("app.alert.open_failed.body")
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// セッションの乗っていない worktree を開く
    private func open(worktree: CollectedWorktree) {
        open(path: worktree.path, name: worktree.name)
    }

    /// その場所を開く。
    ///
    /// **エージェントは起こさない** — 続きの会話が無い場所なので、
    /// 何を始めるかは開いた人が決める。
    ///
    /// 2つの入口を1つの関数にしてあるのは、**違うのが最初の一手だけ**だから。
    /// 許可の待ち方も、失敗したときの伝え方も同じなので、分けて書くと
    /// 片方だけ直る余地が生まれる。
    ///
    /// - Parameters:
    ///   - name: 開けなかったときに出す名前。パスは長すぎてダイアログの
    ///     見出しにならない
    ///   - reusingTab: その場所を開いているタブがあればそこへ行く
    ///     (理由は ItermBridge.sessionID)。**見出しの `+` では false。**
    ///     あれは「ここでもう1枚」と言われているので、
    ///     既にあるタブへ連れて行っては求められたことをしていない
    private func open(path: String, name: String, reusingTab: Bool = true) {
        // 待つ理由は open(taskID:) と同じ
        Task { @MainActor in
            await ItermBridge.settlePermission()

            if reusingTab, let session = ItermBridge.sessionID(inDirectory: path),
               ItermBridge.focus(sessionID: session) {
                return
            }
            guard ItermBridge.openTab(inDirectory: path) else {
                let alert = NSAlert()
                alert.messageText = Localized.text("app.alert.open_failed.title", name)
                alert.informativeText = Localized.text("app.alert.open_failed.body")
                alert.alertStyle = .warning
                alert.runModal()
                return
            }
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
