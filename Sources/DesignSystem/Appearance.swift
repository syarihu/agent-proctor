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
public final class Appearance: ObservableObject {
    // MARK: - 文字の大きさ

    /// 既定は 16。iTerm2 の Toolbelt に出していた頃と同じ大きさに合わせている
    public static let defaultSize: CGFloat = 16
    public static let sizeRange: ClosedRange<CGFloat> = 9...28
    public static let sizeStep: CGFloat = 1

    @Published public var fontSize: CGFloat {
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

    public static let defaultWidth: CGFloat = 280
    /// 下限はタスク名が読める程度、上限は画面の半分を超えない程度
    public static let widthRange: ClosedRange<CGFloat> = 180...1200
    public static let widthStep: CGFloat = 1

    @Published public var sidebarWidth: CGFloat {
        didSet {
            let clamped = Self.clamp(sidebarWidth, to: Self.widthRange)
            if clamped != sidebarWidth {
                sidebarWidth = clamped
                return
            }
            UserDefaults.standard.set(Double(sidebarWidth), forKey: Self.widthKey)
        }
    }

    // MARK: - iTerm2 の幅を詰める

    /// 左に隙間が無いとき、iTerm2 のウィンドウを右へ寄せて場所を空けるか。
    ///
    /// 他人のウィンドウを動かすのは驚かれる振る舞いなので、切れるようにしておく。
    /// 切ってあると、全画面のときサイドバーは画面の端で止まって端末に重なる。
    @Published public var makeRoomForSidebar: Bool {
        didSet { UserDefaults.standard.set(makeRoomForSidebar, forKey: Self.makeRoomKey) }
    }

    // MARK: - タブ番号

    /// 行に iTerm2 のタブ番号 (⌘1〜⌘9) を出すか。
    ///
    /// **切ってあるときは端末に番号を聞きに行かない。** 出さない番号のために
    /// 1秒ごとに Apple Event を1件投げ続けることになる (ItermBridge.focusedTab)。
    /// 見た目だけ消しても、止まるのは描画だけで問い合わせは残ってしまう
    @Published public var showTabNumbers: Bool {
        didSet { UserDefaults.standard.set(showTabNumbers, forKey: Self.showTabNumbersKey) }
    }

    // MARK: - 変更を数える

    /// セッションと worktree の未コミットの変更を数えるか。
    ///
    /// **切ってあるときは git に聞きに行かない。** 数字を消すだけでは、
    /// `git diff --numstat` と `git ls-files --others` は数え直しのたびに
    /// worktree の数だけ起き続ける。上のタブ番号と同じ形
    /// (出さないものを問い合わせ続けない)。
    ///
    /// **NoticeSettings ではなくここに置いたのは、これが見た目の設定だから。**
    /// 消えるのは行に添える数字と、worktree を片付けてよいかの言い切りで、
    /// どちらもサイドバーの見せ方の話に収まる
    @Published public var countChanges: Bool {
        didSet { UserDefaults.standard.set(countChanges, forKey: Self.countChangesKey) }
    }

    // MARK: - 一覧のまとめ方

    /// 何も選んでいないときのまとめ方。
    ///
    /// **Organization を既定にできるのは、gh が無い環境が勝手に
    /// リポジトリごとへ落ちるから** (`resolvedGrouping`)。落ちる先が
    /// これまでの見せ方なので、既定を寄せても誰の一覧も壊れない
    public static let defaultGrouping: GroupingMode = .organization

    /// リポジトリごとか、Organization ごとか。**選んだものをそのまま持つ。**
    ///
    /// gh が使えるかどうかで書き換えないのは、一時的に使えないだけ
    /// (ログインが切れた・ネットワークが無い) のときに、選んだ覚えのない
    /// 設定に戻ってしまうため。使えるかどうかは出すときに見る (`resolvedGrouping`)
    @Published public var groupingMode: GroupingMode {
        didSet { UserDefaults.standard.set(groupingMode.rawValue, forKey: Self.groupingKey) }
    }

    /// Organization でまとめられる状態か。gh に聞くので、
    /// 描くたびには確かめない (答えは Kit 側が覚えている)。
    ///
    /// **前回の答えを覚えておいて、そこから始める。** gh に聞くのはプロセスを
    /// 起こす仕事なので答えが返るまで一拍あり、その間だけリポジトリごとに
    /// 描いてしまう。既定が Organization だと、起動のたびに一覧が組み変わって
    /// 見える。gh を入れたり消したりは滅多に無いので、前回の答えで描き始めて
    /// 違っていたときだけ直すほうが落ち着く
    @Published public var canGroupByOrganization: Bool {
        didSet {
            UserDefaults.standard.set(canGroupByOrganization, forKey: Self.canGroupByOrgKey)
        }
    }

    /// 実際に使うまとめ方。**gh が使えないならリポジトリごとに戻す。**
    /// 持ち主の名前だけの見出しになると、なぜアイコンが出ないのかが画面から
    /// 分からないので、そうなるくらいなら元の見せ方のままにしておく
    public var resolvedGrouping: GroupingMode {
        groupingMode == .organization && canGroupByOrganization ? .organization : .repository
    }

    /// Organization まとめが利用可能かを確かめるプロバイダ。UseCaseTask への直接依存を避けるために注入する
    public static var checkOrganizationAvailability: (@Sendable () async -> Bool)?

    /// gh が使えるかを見に行く。設定画面を開いたときとアプリの起動時に呼ぶ。
    /// プロセスを起こすので、メインスレッドは待たせない
    public func refreshOrganizationAvailability() {
        let check = Self.checkOrganizationAvailability
        Task {
            let available = await Task.detached(priority: .utility) {
                await check?() ?? false
            }.value
            if canGroupByOrganization != available { canGroupByOrganization = available }
        }
    }

    // MARK: - 不透明度 (透明度)

    public static let defaultOpacity: Double = 0.95
    public static let opacityRange: ClosedRange<Double> = 0.2...1.0

    @Published public var opacity: Double {
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

    public static let defaultCustomHex = "#1E1E24"

    @Published public var useCustomBackgroundColor: Bool {
        didSet {
            UserDefaults.standard.set(useCustomBackgroundColor, forKey: Self.useCustomColorKey)
            onAppearanceChange?()
        }
    }

    @Published public var customColorHex: String {
        didSet {
            UserDefaults.standard.set(customColorHex, forKey: Self.customColorKey)
            onAppearanceChange?()
        }
    }

    /// SettingsView の ColorPicker と直接バインドするためのプロパティ
    public var customColor: Color {
        get {
            Color(nsColor: NSColor(hex: customColorHex) ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        }
        set {
            let nsColor = NSColor(newValue)
            customColorHex = nsColor.toHex()
        }
    }

    /// iTerm2 から取得した背景色
    @Published public var itermBackgroundColor: NSColor? {
        didSet { onAppearanceChange?() }
    }

    /// 実際にパネルに適用する背景色（透明度適用済み）
    public var resolvedBackgroundColor: NSColor {
        let base: NSColor
        if useCustomBackgroundColor {
            base = NSColor(hex: customColorHex) ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        } else {
            base = itermBackgroundColor ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1)
        }
        return base.withAlphaComponent(opacity)
    }

    /// パネルなどの描画更新通知
    public var onAppearanceChange: (() -> Void)?

    // MARK: -

    private static let sizeKey = "proctor_font_size"
    private static let widthKey = "proctor_sidebar_width"
    private static let opacityKey = "proctor_opacity"
    private static let useCustomColorKey = "proctor_use_custom_color"
    private static let customColorKey = "proctor_custom_color_hex"
    private static let makeRoomKey = "proctor_make_room"
    private static let groupingKey = "proctor_grouping"
    private static let canGroupByOrgKey = "proctor_can_group_by_org"
    private static let showTabNumbersKey = "proctor_show_tab_numbers"
    private static let countChangesKey = "proctor_count_changes"

    public init() {
        fontSize = Self.load(Self.sizeKey, in: Self.sizeRange, default: Self.defaultSize)
        sidebarWidth = Self.load(Self.widthKey, in: Self.widthRange, default: Self.defaultWidth)

        let savedOpacity = UserDefaults.standard.double(forKey: Self.opacityKey)
        opacity = Self.opacityRange.contains(savedOpacity) ? savedOpacity : Self.defaultOpacity

        useCustomBackgroundColor = UserDefaults.standard.bool(forKey: Self.useCustomColorKey)
        customColorHex = UserDefaults.standard.string(forKey: Self.customColorKey) ?? Self.defaultCustomHex

        // 既定はオン。bool(forKey:) は未設定でも false を返すので、
        // 「保存されていない」と「切ってある」を object の有無で分ける
        makeRoomForSidebar = UserDefaults.standard.object(forKey: Self.makeRoomKey) as? Bool ?? true
        // こちらも既定はオン (未設定と「切ってある」を object の有無で分ける)
        showTabNumbers = UserDefaults.standard
            .object(forKey: Self.showTabNumbersKey) as? Bool ?? true
        // こちらも既定はオン。数えるのが今までの振る舞いなので、
        // 何も選んでいない人の見え方は変えない
        countChanges = UserDefaults.standard
            .object(forKey: Self.countChangesKey) as? Bool ?? true

        // まだ選んでいないときと、知らない値が入っていたときは既定に落とす
        groupingMode = GroupingMode(
            rawValue: UserDefaults.standard.string(forKey: Self.groupingKey) ?? "")
            ?? Self.defaultGrouping
        // 一度も聞いていなければ false から始める。gh を入れていない人に
        // Organization の見出しを一瞬見せるより、出ないところから始めるほうがよい
        canGroupByOrganization = UserDefaults.standard.bool(forKey: Self.canGroupByOrgKey)
        refreshOrganizationAvailability()
    }

    public func resetFontSize() { fontSize = Self.defaultSize }
    public func resetWidth() { sidebarWidth = Self.defaultWidth }
    public func resetOpacity() { opacity = Self.defaultOpacity }
    public func resetBackgroundColor() {
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
    public convenience init?(hex: String) {
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

    public func toHex() -> String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#1E1E24" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
