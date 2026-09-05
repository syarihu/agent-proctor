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

/// アプリケーションのエントリポイントおよび全体協調
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
    /// 変更カウント設定の変更監視用
    private var countObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)  // Dock アイコンを出さない

        Appearance.checkOrganizationAvailability = {
            CheckOrganizationAvailability.check()
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

        // 変更カウント設定の変更を TaskStore に反映する
        store.wantsDiff = { [weak appearance] in appearance?.countChanges ?? true }
        // willSet での発火による旧値参照とメインスレッド負荷を防ぐため、debounce を挟んで反映する
        countObserver = appearance.$countChanges
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
            // サイドバー非表示時は不要な git および GitHub API への問い合わせを抑制する
            self?.store.setCollecting(visible)
            self?.pullRequests.setEnabled(visible)
        }

        notices = NoticeSettings()
        notifier = Notifier()
        notifier.onOpen = { [weak self] id in self?.open(taskID: id) }
        // 通知対象が設定されている場合のみ権限リクエストを行う
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
        // Antigravity の承認待ちはフックが発火しないためウォッチャーで補足し、即時リフレッシュする
        approvals = ApprovalWatcher(store: store) { [weak self] in self?.store.refreshNow() }
        focus = FocusWatcher(
            onFocus: { [weak self] session in self?.store.setFocused(session) },
            onDirectory: { [weak self] path in self?.store.setCurrentDirectory(path) },
            wantsTabNumbers: { [weak self] in self?.appearance.showTabNumbers ?? false },
            onTabNumbers: { [weak self] numbers in self?.store.setTabNumbers(numbers) },
            seenPolicy: { [weak self] in self?.notices.seenPolicy ?? .onOpen },
            onSeen: { [weak self] in self?.store.refreshNow() })

        // オートメーション権限確定後に iTerm2 への問い合わせを行い、ウィンドウ背景色を同期する
        Task { @MainActor in
            await ItermBridge.settlePermission()
            self.chaseBackground(remaining: 30)
        }
    }

    /// 終了時に iTerm2 のウィンドウ幅を元の状態に復元する（willTerminate では通信が間に合わない場合があるためここで実行）
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        sidebar?.restoreRoom()
        return .terminateNow
    }

    /// タスクに対応するタブまたは新規タブで attach を開く
    private func open(taskID: String) {
        // 押下時点の最新の itermSession を参照するため TaskStore の台帳レコードを直接参照する
        guard let task = store.record(id: taskID) else { return }

        // オートメーション権限の確定を待機してからタブ操作を実行する
        Task { @MainActor in
            await ItermBridge.settlePermission()

            if let session = task.itermSession, ItermBridge.focus(sessionID: session) {
                return
            }
            // 起動失敗時は警告ダイアログを表示する
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

    /// セッションが存在しない worktree を開く
    private func open(worktree: CollectedWorktree) {
        open(path: worktree.path, name: worktree.name)
    }

    /// 指定パスを iTerm2 で開く。reusingTab が false（新規タブ追加ボタン等）の場合は既存タブへのフォーカスを行わず新規タブを開く。
    private func open(path: String, name: String, reusingTab: Bool = true) {
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

    /// iTerm2 起動直後などで背景色が取得できるまでリトライする
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

// メインスレッド上での NSApplication および AppDelegate の初期化と実行
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
