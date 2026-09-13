import AppKit
import AppState
import Combine
import DesignSystem
import FeatureDesk
import FeatureMenuBar
import FeatureSettings
import FeatureSidebar
import HotkeyBridge
import ItermBridge
import Model
import Resources
import SwiftUI
import UseCaseNotice
import UseCaseSession
import UseCaseTask

/// アプリケーションのエントリポイントおよび全体協調
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: TaskStore!
    private var appearance: Appearance!
    private var sidebar: SidebarPanel!
    private var officeWindow: OfficeWindow!
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
    /// オフィス窓のホットキー設定の変更監視用
    private var hotkeyObserver: AnyCancellable?
    /// オフィス窓を出したときに前にいたアプリ。
    ///
    /// iTerm2 の hotkey window を引っ込めると、その裏にいたこのアプリが macOS によって
    /// 自動で前へ戻る。人がそちらへ移ったわけではないので、これを「別のアプリへ移った」と
    /// 読むと、端末を引っ込めただけでオフィス窓まで道連れになる
    private var officeHostApp: String?
    /// 自分以外で最後に前へ出たアプリ。
    ///
    /// オフィス窓をメニューバーから開くと、そのクリックで自分が前に出てしまい、
    /// 「窓を出したとき前にいたアプリ」を今の前面から読むと自分自身になる。
    /// 人が戻る先はその1つ手前なので、そちらを覚えておく
    private var lastForeignApp: String?
    /// オフィス窓がいま一番手前にいるか。
    ///
    /// 出したときに一番手前へ出て、次にどれかのアプリが前に出た時点でその座を譲る。
    /// アプリを前面に出さない窓なので、手前かどうかを尋ねられる相手がいない。
    /// 出し入れと、アプリが前に出た合図の2つから、こちらで数えておく
    private var officeIsFrontmost = false

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
        sidebar.onVisibilityChange = { [weak self] _ in
            self?.updateCollectingState()
        }
        sidebar.officeIsFrontmost = { [weak self] in self?.officeIsFrontmost ?? false }

        officeWindow = OfficeWindow(
            store: store, appearance: appearance,
            onOpen: { [weak self] id in
                self?.open(taskID: id)
            })
        officeWindow.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            // 出した時点で前にいたアプリを覚える。アプリを前に出さずに窓だけ重ねるので、
            // このアプリは窓が出ている間ずっと前にいるまま
            if visible { self.officeHostApp = self.hostApp() }
            // 出した窓は一番手前に出る。引っ込めたらその座も無くなる
            self.officeIsFrontmost = visible
            // サイドバーはオフィス窓の下へ回る。あちらが前面に出ない窓なので、
            // 通知では気づけず、ここから知らせるほかない
            self.sidebar?.refreshLevel()
            self.updateCollectingState()
        }
        officeWindow.onClose = { [weak self] in
            self?.updateActivationPolicy()
        }

        // 前回アプリ終了時にオフィスウィンドウが表示されていた場合は自動的に再表示する
        if OfficeWindow.wasOpenOnQuit {
            officeWindow.show()
        }

        registerOfficeHotkey(appearance.officeHotkey)
        // 設定画面で決めたそばから効かせる。@Published は willSet で流れるので、
        // ここで appearance を読み直すと1つ前のキーを登録することになる。
        // 流れてきた値のほうを使う
        hotkeyObserver = appearance.$officeHotkey
            .dropFirst()
            .sink { [weak self] combo in
                Task { @MainActor in self?.registerOfficeHotkey(combo) }
            }
        watchActivation()

        notices = NoticeSettings()
        notifier = Notifier()
        notifier.onOpen = { [weak self] id in self?.open(taskID: id) }
        // 通知対象が設定されている場合のみ権限リクエストを行う
        if !notices.wanted.isEmpty { notifier.requestAuthorizationIfNeeded() }
        noticeWatcher = NoticeWatcher(store: store, settings: notices, notifier: notifier)

        settings = SettingsWindow(appearance: appearance, notices: notices,
                                  notifier: notifier)
        settings.onClose = { [weak self] in
            self?.updateActivationPolicy()
        }

        menuBar = MenuBarController(store: store)
        menuBar.onOpenOffice = { [weak self] in self?.officeWindow.show() }
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
        OfficeWindow.isTerminating = true
        OfficeWindow.setOpenState(officeWindow?.isVisible ?? false)
        sidebar?.restoreRoom()
        return .terminateNow
    }

    /// いずれかのウィンドウ（サイドバーまたはオフィス窓）が表示されているかを監視し、データ収集の稼働状態を切り替える
    private func updateCollectingState() {
        let anyVisible = (sidebar?.isShowing ?? false) || (officeWindow?.isVisible ?? false)
        store.setCollecting(anyVisible)
        pullRequests.setEnabled(anyVisible)
    }

    /// ホットキーを張り替える。
    ///
    /// 押されたらオフィス窓を出し入れする。空にしてあるなら登録しない。
    /// 取れなかった (他アプリが先に持っている) ことは設定画面へ伝える。
    /// 黙って効かないのが一番分かりにくいので、欄の横に但し書きを出させる
    private func registerOfficeHotkey(_ combo: HotkeyCombo?) {
        let registered = GlobalHotkey.set(combo) { [weak self] in
            self?.officeWindow.toggle()
        }
        appearance.officeHotkeyTaken = combo != nil && !registered
    }

    /// 別のアプリへ移ったらオフィス窓を引っ込める。
    ///
    /// 通さない相手は3つある。
    ///
    /// - 自分自身
    /// - iTerm2。見取り図を見て端末で手を動かす、という往復がこの窓の使い方なので、
    ///   そこで消えると押し直しになる
    /// - 窓を出したときに前にいたアプリ (`officeHostApp`)。iTerm2 の hotkey window を
    ///   引っ込めると、その裏にいたこのアプリが自動で前へ戻ってくる。移ったのは人ではなく、
    ///   端末が退いた結果でしかない。
    ///   なお、このアプリは窓を出している間ずっと前にいるので、そこを押しても通知は飛ばない。
    ///   前へ「出てくる」のは他所から戻ってきたときだけで、それがまさにこの場合になる
    ///
    /// この3つ以外が前に出たときだけが、人が本当に別の作業へ移った合図になる。
    /// iTerm2 の hotkey window は自分で引っ込むので、そのとき両方まとめて消える
    private func watchActivation() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            Task { @MainActor in
                guard let self else { return }
                if let bundleID, bundleID != Bundle.main.bundleIdentifier {
                    self.lastForeignApp = bundleID
                }
                // 前に出たアプリは自分のウィンドウを持ち上げるので、
                // オフィス窓は手前ではなくなる。サイドバーは端末の上へ戻ってよい
                if self.officeIsFrontmost {
                    self.officeIsFrontmost = false
                    self.sidebar?.refreshLevel()
                }
                guard self.appearance.hidesOfficeOnDeactivate else { return }
                guard bundleID != Bundle.main.bundleIdentifier,
                      bundleID != ItermBridge.bundleID,
                      bundleID != self.officeHostApp else { return }
                self.officeWindow.hide()
            }
        }
    }

    /// オフィス窓を重ねる相手。
    ///
    /// いま前にいるアプリ。それが自分なら (メニューバーから開いたとき) その1つ手前
    private func hostApp() -> String? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let front, front != Bundle.main.bundleIdentifier { return front }
        return lastForeignApp
    }

    /// 通常ウィンドウがすべて閉じられた場合に activationPolicy を .accessory に戻す。
    ///
    /// オフィス窓はここに数えない。アプリを前に出さずに出入りするパネルになったので、
    /// そもそも .regular を要求しない。数えたままにすると、設定画面を閉じても
    /// オフィス窓が出ている間は Dock にアイコンが残り続ける
    private func updateActivationPolicy() {
        if !(settings?.isVisible ?? false) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func showOpenFailedAlert(displayName: String) {
        let alert = NSAlert()
        alert.messageText = Localized.text("app.alert.open_failed.title", displayName)
        alert.informativeText = Localized.text("app.alert.open_failed.body")
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// iTerm2 等の外部プロセスから呼び出すための proctor 実行ファイルの絶対パス。
    /// iTerm2 の command 実行ではシェルを経由せず直接 execvp されるため $PATH が検索されず、
    /// 相対コマンド名では errno 2（No such file or directory）で失敗する。
    private static var proctorExecutablePath: String {
        // 1. アプリバンドル内の Contents/Helpers/proctor（dev / 配布版共通で確実に同一ビルドを指す）
        let helperPath = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/proctor").path
        if FileManager.default.isExecutableFile(atPath: helperPath) {
            return helperPath
        }
        // 2. ~/bin/proctor（install.sh / switch-cli.sh が張るシンボリックリンク）
        let homeBin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("bin/proctor").path
        if FileManager.default.isExecutableFile(atPath: homeBin) {
            return homeBin
        }
        // 3. /opt/homebrew/bin/proctor
        let brewBin = "/opt/homebrew/bin/proctor"
        if FileManager.default.isExecutableFile(atPath: brewBin) {
            return brewBin
        }
        return "proctor"
    }

    /// タスクに対応するタブまたは新規タブで attach を開く
    private func open(taskID: String) {
        // 押下時点の最新の itermSession を参照するため TaskStore の台帳レコードを直接参照する
        guard let task = store.record(id: taskID) else { return }

        // オートメーション権限の確定を待機してからタブ操作を実行する
        Task { @MainActor in
            await ItermBridge.settlePermission()

            if let session = task.itermSession {
                if ItermBridge.focus(sessionID: session) {
                    return
                }
            }

            let proctor = Self.proctorExecutablePath
            // hotkey window がある場合は表示して attach コマンドを実行する
            if ItermBridge.revealHotkeyWindow() {
                if !ItermBridge.openTab(runningCommand: "\(proctor) attach \(task.id)") {
                    showOpenFailedAlert(displayName: task.displayName)
                }
                return
            }
            // hotkey window が使えない場合は通常の新規タブで attach を開く
            if !ItermBridge.openTab(runningCommand: "\(proctor) attach \(task.id)") {
                showOpenFailedAlert(displayName: task.displayName)
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
