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

    var body: some View {
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        // 画面を開き直したときに、外で変えられていた設定を拾い直す
        .onAppear { launchAtLogin = LoginItem.isEnabled }
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
