import Foundation
import CoreGraphics
import Combine

/// 見た目の設定。
///
/// 設定画面とサイドバーの両方が触るので、値の正本はここに置く。
/// 幅は端をドラッグしても変わるが、その書き込みもここを通す。
/// 2箇所で持つと、片方で変えたときにもう片方が古いままになる。
///
/// 一覧の余白も記号も文字の大きさに追従させてあるので、ここが1つ動けば
/// 行の高さごと変わる。元の iTerm2 パネルが CSS の `--size` 1行で
/// 決めていたのと同じ考え方。
///
/// **didSet の中で自分のプロパティを inout 引数に渡さないこと。**
/// 呼ばれた関数から戻るときに inout の書き戻しが走って didSet が再入し、
/// 際限なく繰り返してスタックを食い潰す。範囲に収める処理は値を返す形にして、
/// 代入はここで1回だけ行う。
@MainActor
final class Appearance: ObservableObject {
    // MARK: - 文字の大きさ

    /// 既定は 16。iTerm2 の Toolbelt に出していた頃と同じ大きさに合わせている
    static let defaultSize: CGFloat = 16
    static let sizeRange: ClosedRange<CGFloat> = 9...28
    static let sizeStep: CGFloat = 1

    @Published var fontSize: CGFloat {
        didSet {
            let clamped = Self.clamp(fontSize, to: Self.sizeRange)
            if clamped != fontSize {
                // ここでもう一度 didSet に入るが、次はもう収まっているので止まる
                fontSize = clamped
                return
            }
            UserDefaults.standard.set(Double(fontSize), forKey: Self.sizeKey)
        }
    }

    // MARK: - サイドバーの幅

    static let defaultWidth: CGFloat = 280
    /// 下限はタスク名が読める程度、上限は画面の半分を超えない程度
    static let widthRange: ClosedRange<CGFloat> = 180...1200
    static let widthStep: CGFloat = 1

    @Published var sidebarWidth: CGFloat {
        didSet {
            let clamped = Self.clamp(sidebarWidth, to: Self.widthRange)
            if clamped != sidebarWidth {
                sidebarWidth = clamped
                return
            }
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.widthKey)
        }
    }

    // MARK: -

    private static let sizeKey = "proctor_font_size"
    private static let widthKey = "proctor_sidebar_width"

    init() {
        fontSize = Self.load(Self.sizeKey, in: Self.sizeRange, default: Self.defaultSize)
        sidebarWidth = Self.load(Self.widthKey, in: Self.widthRange,
                                 default: Self.defaultWidth)
    }

    func resetFontSize() { fontSize = Self.defaultSize }
    func resetWidth() { sidebarWidth = Self.defaultWidth }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func load(_ key: String, in range: ClosedRange<CGFloat>,
                             default fallback: CGFloat) -> CGFloat {
        let saved = CGFloat(UserDefaults.standard.double(forKey: key))
        return range.contains(saved) ? saved : fallback
    }
}
