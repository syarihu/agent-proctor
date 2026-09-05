import AppKit
import DesignSystem
import ItermBridge
import Model
import Resources
import SwiftUI
import UseCaseSession
import Utility

/// アプリ全般の設定画面。
struct SettingsView: View {
    @ObservedObject var appearance: Appearance
    @ObservedObject var notices: NoticeSettings
    let notifier: NotificationPermissionAuthorizer

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    /// 通知の許可状態（非同期取得完了までは nil）
    @State private var notifyPermission: NotificationPermissionStatus?
    /// 通知許可の要求中フラグ
    @State private var askingNotify = false
    /// iTerm2 オートメーション権限状態
    @State private var automation = AutomationPermission.state()
    /// オートメーション許可の要求中フラグ
    @State private var asking = false

    var body: some View {
        VStack(spacing: 0) {
            form
            Text(AppVersion.current.map { Localized.text("app.settings.version", $0) }
                 ?? Localized.text("app.settings.version.development"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        // 最長ラベル（「通知を消すタイミング」等）が折り返されないよう幅を固定
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var form: some View {
        Form {
            Section {
                slider(title: Localized.text("app.settings.font_size"),
                       value: $appearance.fontSize,
                       range: Appearance.sizeRange,
                       step: Appearance.sizeStep,
                       unit: "pt",
                       isDefault: appearance.fontSize == Appearance.defaultSize,
                       reset: appearance.resetFontSize)

                slider(title: Localized.text("app.settings.width"),
                       value: $appearance.sidebarWidth,
                       range: Appearance.widthRange,
                       step: Appearance.widthStep,
                       unit: "pt",
                       isDefault: appearance.sidebarWidth == Appearance.defaultWidth,
                       reset: appearance.resetWidth)

                slider(title: Localized.text("app.settings.opacity"),
                       value: Binding(
                           get: { CGFloat(appearance.opacity * 100) },
                           set: { appearance.opacity = Double($0 / 100) }
                       ),
                       range: 20...100,
                       step: 1,
                       unit: "%",
                       isDefault: abs(appearance.opacity - Appearance.defaultOpacity) < 0.005,
                       reset: appearance.resetOpacity)

                LabeledContent(Localized.text("app.settings.background")) {
                    HStack(spacing: 12) {
                        Picker("", selection: $appearance.useCustomBackgroundColor) {
                            Text(Localized.text("app.settings.background.match_iterm")).tag(false)
                            Text(Localized.text("app.settings.background.custom")).tag(true)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 180)

                        if appearance.useCustomBackgroundColor {
                            ColorPicker("", selection: $appearance.customColor, supportsOpacity: false)
                                .labelsHidden()
                                .frame(width: 32)
                        }

                        Spacer()

                        Button(Localized.text("app.settings.reset"), action: appearance.resetBackgroundColor)
                            .disabled(!appearance.useCustomBackgroundColor && appearance.customColorHex == Appearance.defaultCustomHex)
                    }
                }
                LabeledContent(Localized.text("app.settings.grouping")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $appearance.groupingMode) {
                            Text(Localized.text("app.settings.grouping.repository"))
                                .tag(GroupingMode.repository)
                            Text(Localized.text("app.settings.grouping.organization"))
                                .tag(GroupingMode.organization)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 240)
                        // gh に頼っているのは持ち主のアイコンだけだが、
                        // それが出ないなら選ぶ意味が薄いので丸ごと止める
                        .disabled(!appearance.canGroupByOrganization)

                        // 選べない理由は、選べない場所のすぐ隣に置く。
                        // 節の下 (footer) にまとめると、どの項目の話か分からない
                        if !appearance.canGroupByOrganization {
                            Text(Localized.text("app.settings.grouping.needs_gh"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Toggle(Localized.text("app.settings.tab_numbers"),
                       isOn: $appearance.showTabNumbers)
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(Localized.text("app.settings.count_changes"),
                           isOn: $appearance.countChanges)
                    // 何が起きるかは、切ってあるときだけ、そのトグルの真下に出す。
                    // 節の下 (footer) にまとめると、どの項目の話か分からない
                    // (上の「Organization でまとめる」と同じ扱い)。
                    // 入れてあるときに出さないのは、これが今までどおりだから
                    if !appearance.countChanges {
                        Text(Localized.text("app.settings.count_changes.off"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(Localized.text("app.settings.make_room"),
                       isOn: $appearance.makeRoomForSidebar)
            } header: {
                Text(Localized.text("app.settings.sidebar_section"))
            } footer: {
                Text(Localized.text("app.settings.sidebar_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // onChange の2引数版は macOS 14 からなので、
                // 書き込みを受けるバインディングを自分で作る
                Toggle(Localized.text("app.settings.launch_at_login"), isOn: Binding(
                    get: { launchAtLogin },
                    set: { apply(launchAtLogin: $0) }))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text(Localized.text("app.settings.launch_section"))
            }

            Section {
                LabeledContent(Localized.text("app.settings.unread")) {
                    Picker("", selection: $notices.seenPolicy) {
                        Text(Localized.text("app.settings.unread.on_open"))
                            .tag(MarkSessionSeen.Policy.onOpen)
                        Text(Localized.text("app.settings.unread.until_cleared"))
                            .tag(MarkSessionSeen.Policy.untilCleared)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    // 選択肢の文言長に合わせてレイアウトを自動調整する
                }
            } header: {
                Text(Localized.text("app.settings.unread_section"))
            } footer: {
                Text(Localized.text("app.settings.unread_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle(Localized.text("app.settings.notify.waiting"),
                       isOn: $notices.onWaiting)
                Toggle(Localized.text("app.settings.notify.done"), isOn: $notices.onDone)
                Toggle(Localized.text("app.settings.notify.failed"), isOn: $notices.onFailed)
            } header: {
                Text(Localized.text("app.settings.notify_section"))
            } footer: {
                Text(Localized.text("app.settings.notify_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                LabeledContent(Localized.text("app.settings.notify")) {
                    HStack(spacing: 12) {
                        Text(notifyState)
                            .foregroundStyle(notifyPermission == .granted
                                             ? .secondary : .primary)
                        Spacer()
                        Button(notifyAction, action: requestNotify)
                            // 問い合わせ実行中は多重操作を抑止する
                            .disabled(askingNotify || notifyPermission == nil
                                      || notifyPermission == .unavailable)
                    }
                }
                LabeledContent(Localized.text("app.settings.automation")) {
                    HStack(spacing: 12) {
                        Text(automationState)
                            .foregroundStyle(automation == .granted ? .secondary : .primary)
                        Spacer()
                        Button(automationAction, action: requestAutomation)
                            // iTerm2 未起動時は TCC にアプリ一覧が表示されないため無効化する
                            .disabled(asking || automation == .targetNotRunning)
                    }
                }
            } header: {
                Text(Localized.text("app.settings.automation_section"))
            } footer: {
                Text(Localized.text("app.settings.automation_footer"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // 画面表示時に外部で変更された設定（ログイン項目、権限、gh 状態）を再取得する
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            automation = AutomationPermission.state()
            appearance.refreshOrganizationAvailability()
            refreshNotifyPermission()
        }
        // 通知対象を有効化した際に未決定状態であれば即座に許可ダイアログを要求する
        .onChange(of: notices.wanted.isEmpty) { empty in
            guard !empty, notifyPermission == .undecided else { return }
            requestNotify()
        }
        // システム設定等からアプリにフォーカスが戻った際に、変更された権限状態を再取得する
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            automation = AutomationPermission.state()
            refreshNotifyPermission()
            appearance.refreshOrganizationAvailability()
        }
    }

    private var automationState: String {
        switch automation {
        case .granted: return Localized.text("app.settings.automation.granted")
        case .denied: return Localized.text("app.settings.automation.denied")
        case .undecided: return Localized.text("app.settings.automation.undecided")
        case .targetNotRunning: return Localized.text("app.settings.automation.not_running")
        case .unknown: return Localized.text("app.settings.automation.unknown")
        }
    }

    /// 未決定時は許可ダイアログを要求し、決定済みの場合はシステム設定画面を開く
    private var automationAction: String {
        automation == .undecided
            ? Localized.text("app.settings.automation.ask")
            : Localized.text("app.action.open_settings")
    }

    private var notifyState: String {
        switch notifyPermission {
        case .granted: return Localized.text("app.settings.notify.granted")
        case .denied: return Localized.text("app.settings.notify.denied")
        case .undecided: return Localized.text("app.settings.notify.undecided")
        case .unavailable: return Localized.text("app.settings.notify.unavailable")
        // まだ聞き終わっていない。空にせず、確かめている最中だと分かる字を出す
        case nil: return Localized.text("app.settings.notify.checking")
        }
    }

    /// まだ決まっていないときだけダイアログを出せる。
    /// それ以外はシステム設定へ送るしかない (オートメーションと同じ事情)
    private var notifyAction: String {
        notifyPermission == .undecided
            ? Localized.text("app.settings.automation.ask")
            : Localized.text("app.action.open_settings")
    }

    private func requestNotify() {
        guard notifyPermission == .undecided else {
            notifier.openSettings()
            return
        }
        // 答えが返ってから映す。尋ねている最中に読むと、まだ
        // 「まだ尋ねていません」のままの答えが返ってくる
        askingNotify = true
        Task {
            notifyPermission = await notifier.requestAuthorization()
            askingNotify = false
        }
    }

    private func refreshNotifyPermission() {
        Task { notifyPermission = await notifier.permission() }
    }

    private func requestAutomation() {
        guard automation == .undecided else {
            AutomationPermission.openSettings()
            return
        }
        // 尋ねる経路はメインスレッドで呼べない (理由は AutomationPermission.request)。
        // 待っている間はボタンを止めて、ダイアログが重ならないようにする
        asking = true
        Task {
            automation = await AutomationPermission.request()
            asking = false
        }
    }

    /// つまみ・現在値・戻すボタンの1行。項目が増えても形が揃うようにまとめる
    @ViewBuilder
    private func slider(title: String, value: Binding<CGFloat>,
                        range: ClosedRange<CGFloat>, step: CGFloat,
                        unit: String = "pt",
                        isDefault: Bool, reset: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                // Slider に step を渡すと全刻みに目盛り線が描画されて視認性が悪化するため、
                // Slider 自体は連続値として扱い、Binding の setter で値を丸める
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = (($0 / step).rounded() * step) }
                ), in: range)
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
                Button(Localized.text("app.settings.reset"), action: reset)
                    .disabled(isDefault)
            }
        }
    }

    private func apply(launchAtLogin wanted: Bool) {
        do {
            try LoginItem.set(wanted)
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        // 処理成否に関わらず実際の登録状態を再取得してトグルに同期する
        launchAtLogin = LoginItem.isEnabled
    }
}
