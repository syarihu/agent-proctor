import DesignSystem
import Resources
import SwiftUI

/// 一覧と俯瞰を切り替える。
///
/// `GroupingTabs` の隣に置くが、あちらのセグメントには足さない。
/// あれは「同じ一覧をどう束ねるか」の選択で、俯瞰は束ね方ではないため
/// (足すと `resolvedGrouping` や `TaskGrouping.pending` に束ね方でないものが流れ込む)。
///
/// 文字ではなく記号なのは、まとめ方のタブに幅を譲るため。
/// 狭いサイドバーでは `GroupingTabs` が記号版に落ちるので、そこで幅を取り合いたくない
struct ModeToggle: View {
    let base: CGFloat
    @ObservedObject var appearance: Appearance

    var body: some View {
        Button {
            appearance.sidebarMode = appearance.sidebarMode == .list ? .desk : .list
        } label: {
            Image(systemName: appearance.sidebarMode == .list ? "building.2" : "list.bullet")
                .font(.system(size: base * 0.8))
                .foregroundStyle(Palette.dim)
                .frame(width: base * 1.6, height: base * 1.3)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 押すと何になるかを言う。いまどちらかではなく、押した先を名乗らせる
        .help(Localized.text(appearance.sidebarMode == .list
                             ? "app.mode.show_desk" : "app.mode.show_list"))
        .accessibilityLabel(Localized.text(appearance.sidebarMode == .list
                                           ? "app.mode.show_desk" : "app.mode.show_list"))
    }
}
