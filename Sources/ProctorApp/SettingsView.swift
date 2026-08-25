import AppKit
import ProctorKit
import SwiftUI

/// 設定画面。
///
/// もともとメニューバーの中に項目として並べていたが、
/// 文字の大きさのように「少しずつ動かして確かめたい」ものはメニューだと
/// 開き直すたびに手が止まる。ここに集めて、動かしながら結果を見られるようにする。
///
/// サイドバーは Appearance を見て描いているので、
/// つまみを動かすとその場で反映される。プレビューは要らない。
struct SettingsView: View {
    @ObservedObject var appearance: Appearance

    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    // 読むだけなら即返るので、最初の描画からほんとうの状態を出せる。
    // 一瞬だけ違う状態が見えると、それが答えだと思われてしまう
    @State private var automation = AutomationPermission.state()
    /// 尋ねている間。答えを待つ間にもう一度押せると、ダイアログが重なる
    @State private var asking = false

    var body: some View {
        // 版はどの節にも属さないので Form の外に置く。
        // 節にすると「設定できる項目」に見えてしまう
        VStack(spacing: 0) {
            form
            // 版が無いときは文ごと差し替える。"Version %@" の穴に
            // "development build" を差すと "Version development build" になり、
            // 文にならない。**穴に入れる語は、どんな語でも文になる保証が作れない**
            Text(AppVersion.current.map { Localized.text("app.settings.version", $0) }
                 ?? Localized.text("app.settings.version.development"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 12)
        }
        .frame(width: 460)
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
                LabeledContent(Localized.text("app.settings.automation")) {
                    HStack(spacing: 12) {
                        Text(automationState)
                            .foregroundStyle(automation == .granted ? .secondary : .primary)
                        Spacer()
                        Button(automationAction, action: requestAutomation)
                            // iTerm2 が居ないときに設定を開かせても行き止まりになる。
                            // 一度も尋ねていなければ TCC に記録が無く、
                            // オートメーションの一覧にこのアプリの行が出てこない
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
        // 画面を開き直したときに、外で変えられていた設定を拾い直す
        .onAppear {
            launchAtLogin = LoginItem.isEnabled
            automation = AutomationPermission.state()
            // gh にログインし直したあと、開き直せば選べるようになってほしい
            appearance.refreshOrganizationAvailability()
        }
        // この画面が一番出す動作は「システム設定を開く」で、それは設定ウィンドウを
        // 閉じない。onAppear だけだと、向こうで許可して戻ってきても表示が
        // 「許可されていません」のままになる。前面に戻った時点で見に行く。
        //
        // 尋ねている最中にも飛んでくる (ダイアログを閉じるとアプリが前面に戻る) が、
        // **どちらが後に代入されても同じ値になるので競合しない**。
        // ここも request() も TCC という同じ正本を読みに行くだけで、
        // 後から読んだほうが必ず新しい。片方が答えを手元で組み立てたり
        // 覚え込んだりするようになると、この前提は崩れる
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            automation = AutomationPermission.state()
            // gh も同じ理由でここに要る。「gh auth login を済ませると選べる」と
            // 案内しておきながら、端末で済ませて戻ってきても止まったままだと、
            // 案内どおりにやったのに効かなかったように見える。
            // Kit 側は「使えない」を60秒しか持ち越さないので、ここで聞き直せば拾える
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

    /// まだ決まっていないときだけ、ここからダイアログを出せる。
    /// それ以外は設定を開くしかない (理由は AutomationPermission)
    private var automationAction: String {
        automation == .undecided
            ? Localized.text("app.settings.automation.ask")
            : Localized.text("app.action.open_settings")
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
                // Slider に step を渡すと macOS は目盛りを描く。
                // 幅は 180〜1200 を 1pt 刻みにしているので目盛りが 1021 本並び、
                // つまみの下が白い線で埋まってしまう。
                // 刻みは書き込み側で丸めて、部品には連続値として渡す
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = (($0 / step).rounded() * step) }
                ), in: range)
                Text("\(Int(value.wrappedValue))\(unit)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // 数字の桁で幅が動くと、つまみまで揺れて掴みにくい
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
        // 成否にかかわらず、実際の状態をスイッチに反映する。
        // 失敗したのに入ったままだと、登録できたと誤解する
        launchAtLogin = LoginItem.isEnabled
    }
}
