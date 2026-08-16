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
                slider(title: "文字の大きさ",
                       value: $appearance.fontSize,
                       range: Appearance.sizeRange,
                       step: Appearance.sizeStep,
                       isDefault: appearance.fontSize == Appearance.defaultSize,
                       reset: appearance.resetFontSize)

                slider(title: "幅",
                       value: $appearance.sidebarWidth,
                       range: Appearance.widthRange,
                       step: Appearance.widthStep,
                       isDefault: appearance.sidebarWidth == Appearance.defaultWidth,
                       reset: appearance.resetWidth)
            } header: {
                Text("サイドバー")
            } footer: {
                Text("行の余白も文字の大きさに合わせて変わります。"
                     + "幅はサイドバーの左端をドラッグしても変えられます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // onChange の2引数版は macOS 14 からなので、
                // 書き込みを受けるバインディングを自分で作る
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { launchAtLogin },
                    set: { apply(launchAtLogin: $0) }))
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("起動")
            } footer: {
                Text("入れておくと、次からは自分で起動しなくても居ます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                        isDefault: Bool, reset: @escaping () -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 12) {
                Slider(value: value, in: range, step: step)
                Text("\(Int(value.wrappedValue))pt")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    // 数字の桁で幅が動くと、つまみまで揺れて掴みにくい
                    .frame(width: 52, alignment: .trailing)
                Button("もとに戻す", action: reset)
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
