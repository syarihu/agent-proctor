import Foundation
import AppKit
import SwiftUI
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

    // MARK: - 不透明度 (透明度)

    static let defaultOpacity: Double = 0.95
    static let opacityRange: ClosedRange<Double> = 0.2...1.0

    @Published var opacity: Double {
        didSet {
            let clamped = min(max(opacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
            if clamped != opacity {
                opacity = clamped
                return
            }
            UserDefaults.standard.set(opacity, forKey: Self.opacityKey)
            onAppearanceChange?()
        }
    }

    // MARK: - 背景色

    static let defaultCustomHex = "#1E1E24"

    @Published var useCustomBackgroundColor: Bool {
        didSet {
            UserDefaults.standard.set(useCustomBackgroundColor, forKey: Self.useCustomColorKey)
            onAppearanceChange?()
        }
    }

    @Published var customColorHex: String {
        didSet {
            UserDefaults.standard.set(customColorHex, forKey: Self.customColorKey)
            onAppearanceChange?()
        }
    }

    /// SettingsView の ColorPicker と直接バインドするためのプロパティ
    var customColor: Color {
        get {
            Color(nsColor: NSColor(hex: customColorHex) ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        }
        set {
            let nsColor = NSColor(newValue)
            customColorHex = nsColor.toHex()
        }
    }

    /// iTerm2 から取得した背景色
    @Published var itermBackgroundColor: NSColor? {
        didSet { onAppearanceChange?() }
    }

    /// 実際にパネルに適用する背景色（透明度適用済み）
    var resolvedBackgroundColor: NSColor {
        let base: NSColor
        if useCustomBackgroundColor {
            base = NSColor(hex: customColorHex) ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        } else {
            base = itermBackgroundColor ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        }
        return base.withAlphaComponent(opacity)
    }

    /// パネルなどの描画更新通知
    var onAppearanceChange: (() -> Void)?

    // MARK: -

    private static let sizeKey = "proctor_font_size"
    private static let widthKey = "proctor_sidebar_width"
    private static let opacityKey = "proctor_opacity"
    private static let useCustomColorKey = "proctor_use_custom_color"
    private static let customColorKey = "proctor_custom_color_hex"

    init() {
        fontSize = Self.load(Self.sizeKey, in: Self.sizeRange, default: Self.defaultSize)
        sidebarWidth = Self.load(Self.widthKey, in: Self.widthRange, default: Self.defaultWidth)

        let savedOpacity = UserDefaults.standard.double(forKey: Self.opacityKey)
        opacity = Self.opacityRange.contains(savedOpacity) ? savedOpacity : Self.defaultOpacity

        useCustomBackgroundColor = UserDefaults.standard.bool(forKey: Self.useCustomColorKey)
        customColorHex = UserDefaults.standard.string(forKey: Self.customColorKey) ?? Self.defaultCustomHex
    }

    func resetFontSize() { fontSize = Self.defaultSize }
    func resetWidth() { sidebarWidth = Self.defaultWidth }
    func resetOpacity() { opacity = Self.defaultOpacity }
    func resetBackgroundColor() {
        useCustomBackgroundColor = false
        customColorHex = Self.defaultCustomHex
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private static func load(_ key: String, in range: ClosedRange<CGFloat>,
                             default fallback: CGFloat) -> CGFloat {
        let saved = CGFloat(UserDefaults.standard.double(forKey: key))
        return range.contains(saved) ? saved : fallback
    }
}

extension NSColor {
    convenience init?(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        guard Scanner(string: trimmed).scanHexInt64(&int) else { return nil }
        let r, g, b: CGFloat
        switch trimmed.count {
        case 6:
            r = CGFloat((int >> 16) & 0xFF) / 255
            g = CGFloat((int >> 8) & 0xFF) / 255
            b = CGFloat(int & 0xFF) / 255
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    func toHex() -> String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#1E1E24" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
