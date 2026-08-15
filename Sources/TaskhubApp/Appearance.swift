import Foundation
import CoreGraphics
import Combine

/// 見た目の設定。今のところ文字の大きさだけ。
///
/// 一覧の余白も記号も文字の大きさに追従させてあるので、ここが1つ動けば
/// 行の高さごと変わる。元の iTerm2 パネルが CSS の `--size` 1行で
/// 決めていたのと同じ考え方。
@MainActor
final class Appearance: ObservableObject {
    /// 既定は 16。iTerm2 の Toolbelt に出していた頃と同じ大きさに合わせている
    static let defaultSize: CGFloat = 16
    static let range: ClosedRange<CGFloat> = 9...28
    static let step: CGFloat = 1

    private static let key = "taskhub_font_size"

    @Published var fontSize: CGFloat {
        didSet {
            let clamped = min(max(fontSize, Self.range.lowerBound), Self.range.upperBound)
            if clamped != fontSize {
                fontSize = clamped
                return
            }
            UserDefaults.standard.set(Double(fontSize), forKey: Self.key)
        }
    }

    init() {
        let saved = UserDefaults.standard.double(forKey: Self.key)
        fontSize = Self.range.contains(CGFloat(saved))
            ? CGFloat(saved)
            : Self.defaultSize
    }

    var canGrow: Bool { fontSize < Self.range.upperBound }
    var canShrink: Bool { fontSize > Self.range.lowerBound }

    func grow() { fontSize += Self.step }
    func shrink() { fontSize -= Self.step }
    func reset() { fontSize = Self.defaultSize }
}
