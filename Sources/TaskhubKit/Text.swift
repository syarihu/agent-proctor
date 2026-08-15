import Foundation

/// 端末に出すときだけ色を付ける。パイプやファイルに流すときは素の文字にする。
public func color(_ code: String, _ text: String) -> String {
    isatty(1) == 1 ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
}

/// 進捗の知らせ。--json の出力を汚さないよう stderr に出す。
public func info(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

/// 全角を2桁として数えた表示幅。日本語ラベルを含む表を揃えるのに使う。
///
/// 色付けした文字列をそのまま渡せるよう、エスケープシーケンスは数えない。
public func displayWidth(_ text: String) -> Int {
    let range = NSRange(text.startIndex..., in: text)
    let plain = ansiPattern.stringByReplacingMatches(
        in: text, range: range, withTemplate: "")
    return plain.unicodeScalars.reduce(0) { $0 + ($1.isEastAsianWide ? 2 : 1) }
}

public func pad(_ text: String, _ size: Int) -> String {
    text + String(repeating: " ", count: max(0, size - displayWidth(text)))
}

public func humanAge(_ epoch: Int) -> String {
    let delta = max(0, Int(Date().timeIntervalSince1970) - epoch)
    if delta < 60 { return "\(delta)s" }
    if delta < 3600 { return "\(delta / 60)m" }
    if delta < 86400 { return "\(delta / 3600)h" }
    return "\(delta / 86400)d"
}

public func slugify(_ text: String) -> String {
    let replaced = text.map { ch -> Character in
        (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
    }
    let collapsed = String(replaced)
        .split(separator: "-", omittingEmptySubsequences: true)
        .joined(separator: "-")
        .lowercased()
    return collapsed.isEmpty ? "task" : collapsed
}

extension Unicode.Scalar {
    /// East Asian Width が W か F か。Python の unicodedata.east_asian_width 相当を、
    /// 表を揃えるのに足りる粒度で持つ。
    var isEastAsianWide: Bool {
        switch value {
        case 0x1100...0x115F,      // ハングル字母
             0x2E80...0x303E,      // CJK 部首・記号
             0x3041...0x33FF,      // かな・CJK 互換
             0x3400...0x4DBF,      // CJK 拡張A
             0x4E00...0x9FFF,      // CJK 統合漢字
             0xA000...0xA4CF,      // イ文字
             0xAC00...0xD7A3,      // ハングル音節
             0xF900...0xFAFF,      // CJK 互換漢字
             0xFE30...0xFE6F,      // CJK 互換形
             0xFF00...0xFF60,      // 全角英数・記号
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,    // 絵文字
             0x1F900...0x1F9FF,
             0x20000...0x2FFFD,
             0x30000...0x3FFFD:
            return true
        default:
            return false
        }
    }
}
