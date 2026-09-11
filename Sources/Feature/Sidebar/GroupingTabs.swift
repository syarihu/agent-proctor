import DesignSystem
import Resources
import SwiftUI

/// まとめ方を切り替えるタブ。
///
/// Finder の表示切り替えと同じセグメントコントロール。
/// 文字で出すのが分かりやすいが、サイドバーは 180pt まで縮むので入らなくなる。
/// `ViewThatFits` に文字版と記号版を渡し、入るほうを出す。
struct GroupingTabs: View {
    let base: CGFloat
    @ObservedObject var appearance: Appearance

    var body: some View {
        ViewThatFits(in: .horizontal) {
            tabs(labelled: true)
            tabs(labelled: false)
        }
        // 選ばれたほうはフィルタボタンの手前まで伸ばす。
        // どちらを選ぶかは自然な幅どうしの比較なので、伸ばしても判定は変わらない
        .frame(maxWidth: .infinity)
    }

    private func tabs(labelled: Bool) -> some View {
        Picker(Localized.text("app.filter.grouping"), selection: selection) {
            ForEach(modes, id: \.rawValue) { mode in
                Group {
                    if labelled {
                        Text(tabLabel(mode))
                    } else {
                        Image(systemName: glyph(mode))
                    }
                }
                // 読み上げの名前は別に持つ。記号には名前が無く、
                // 文字のほうも Organization は縮めた呼び方なので、どちらも正式な名前で読ませる。
                // .help はツールチップで、読み上げの名前にはならない
                .accessibilityLabel(label(mode))
                .help(label(mode))
                .tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .font(.system(size: base * 0.75))
    }

    /// 出すタブ。
    ///
    /// 持ち主そのものは git の remote から引けるので段は作れる。gh が要るのは
    /// 持ち主のアイコンのほうで、それが出ないなら段が増えるだけなので organization は並べない。
    /// Picker はセグメント1つだけを無効にできないため、選べないものを出さないことで表す
    private var modes: [GroupingMode] {
        appearance.canGroupByOrganization
            ? [.organization, .repository]
            : [.repository]
    }

    /// 選択は resolvedGrouping を読む。
    ///
    /// 保存値をそのまま読むと、gh が落ちて organization に解決されなくなったときに
    /// どのタブも選ばれていない状態になる。出ている一覧と選択を一致させる
    private var selection: Binding<GroupingMode> {
        Binding(get: { appearance.resolvedGrouping },
                set: { appearance.groupingMode = $0 })
    }

    private func glyph(_ mode: GroupingMode) -> String {
        switch mode {
        case .repository: return "folder"
        case .organization: return "person.2"
        }
    }

    /// タブに出す名前。
    ///
    /// Organization だけ別に持つのは、そのまま出すと既定幅でも入らず記号に落ちてしまうから。
    /// 短い呼び方は言語ごとに違う (日本語は「組織」、英語は "Org")。
    /// 正式な名前のほうはツールチップで出す
    private func tabLabel(_ mode: GroupingMode) -> String {
        mode == .organization
            ? Localized.text("app.filter.grouping.organization.short")
            : label(mode)
    }

    private func label(_ mode: GroupingMode) -> String {
        switch mode {
        case .repository: return Localized.text("app.filter.grouping.repository")
        case .organization: return Localized.text("app.filter.grouping.organization")
        }
    }
}
