import Foundation

/// ホットキーに使う修飾キー。
///
/// `NSEvent.ModifierFlags` をそのまま持たないのは、Model に AppKit を持ち込まないため。
/// 端末に出すときの Carbon の値も、記録するときの AppKit の値も、変換は外側でやる
public struct HotkeyModifiers: OptionSet, Codable, Equatable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = HotkeyModifiers(rawValue: 1 << 0)
    public static let option = HotkeyModifiers(rawValue: 1 << 1)
    public static let shift = HotkeyModifiers(rawValue: 1 << 2)
    public static let command = HotkeyModifiers(rawValue: 1 << 3)

    /// 単独では押せない修飾キーを含んでいるか。
    ///
    /// Shift だけのホットキーは、大文字を打つたびに発火するものになってしまう。
    /// 押しても何も起きないキーが1つは要る
    public var hasNonShift: Bool {
        !intersection([.control, .option, .command]).isEmpty
    }

    /// Apple の並び (⌃⌥⇧⌘) に揃えた記号
    public var symbols: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }
}

/// 全体ホットキーの押しかた1つ。
public struct HotkeyCombo: Codable, Equatable, Sendable {
    /// `NSEvent.keyCode` と同じ仮想キーコード。登録するときはこれを使う
    public let keyCode: UInt16
    public let modifiers: HotkeyModifiers
    /// 表示に使うキーの名前 ("O"、"Space" など)。
    ///
    /// キーコードから引き直さないのは、どの文字が出るかがキーボード配列で変わるため。
    /// 記録したその打鍵から取った文字を、そのまま覚えておく
    public let label: String

    public init(keyCode: UInt16, modifiers: HotkeyModifiers, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// 設定画面やメニューに出す表記
    public var displayText: String { modifiers.symbols + label }

    /// 登録してよい組み合わせか。
    /// 修飾キーが無い、または Shift だけのものは、普通の入力を奪ってしまう
    public var isRegistrable: Bool { modifiers.hasNonShift }

    // MARK: - 保存

    /// UserDefaults に入れるための1行。
    /// 独自の区切り文字ではなく JSON にしておくと、項目が増えたときに読み書きが片方だけ古びない
    public var stored: String {
        guard let data = try? JSONEncoder().encode(self),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public init?(stored text: String) {
        guard !text.isEmpty, let data = text.data(using: .utf8),
              let combo = try? JSONDecoder().decode(HotkeyCombo.self, from: data) else { return nil }
        self = combo
    }
}
