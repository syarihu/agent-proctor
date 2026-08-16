import Foundation
import TaskhubKit

/// 端末に出すための道具。色も桁揃えも CLI だけの関心なので、
/// 共有の TaskhubKit には置かない (アプリは SwiftUI で別に色を持っている)。
enum Terminal {
    /// 端末に出すときだけ色を付ける。パイプやファイルに流すときは素の文字にする。
    static func color(_ code: String, _ text: String) -> String {
        isatty(1) == 1 ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// 進捗の知らせ。--json の出力を汚さないよう stderr に出す。
    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// 状態ごとの ANSI 色。記号とラベルは TaskhubKit の TaskStatus が持つ
    static let statusColors: [String: String] = [
        TaskStatus.idle: "2",
        TaskStatus.running: "36",
        TaskStatus.waiting: "33",
        TaskStatus.done: "32",
        TaskStatus.failed: "31",
        TaskStatus.missing: "31",
    ]

    /// 状態を (表示用のラベル, ANSI の色) にする。
    static func style(_ status: String) -> (label: String, color: String) {
        ("\(TaskStatus.mark(status)) \(TaskStatus.label(status))",
         statusColors[status] ?? "0")
    }

    /// 差分を人向けの1セルに整形する。
    static func diff(_ counts: DiffCounts) -> String {
        var parts: [String] = []
        if counts.added > 0 { parts.append(color("32", "+\(counts.added)")) }
        if counts.removed > 0 { parts.append(color("31", "-\(counts.removed)")) }
        if counts.untracked > 0 { parts.append(color("36", "?\(counts.untracked)")) }
        return parts.joined(separator: " ")
    }

    static func age(_ epoch: Int) -> String {
        elapsed(max(0, Int(Date().timeIntervalSince1970) - epoch))
    }

    static func elapsed(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }

    // MARK: - 桁揃え

    private static let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")

    /// 全角を2桁として数えた表示幅。日本語ラベルを含む表を揃えるのに使う。
    ///
    /// 色付けした文字列をそのまま渡せるよう、エスケープシーケンスは数えない。
    static func width(_ text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        let plain = ansiPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
        return plain.unicodeScalars.reduce(0) { $0 + ($1.isEastAsianWide ? 2 : 1) }
    }

    static func pad(_ text: String, _ size: Int) -> String {
        text + String(repeating: " ", count: max(0, size - width(text)))
    }

    /// 表を1つ書く。列の幅は中身から決める。
    static func table(headers: [String], rows: [[String]]) {
        let widths = (0..<headers.count).map { i in
            max(width(headers[i]), rows.map { width($0[i]) }.max() ?? 0)
        }
        let line = { (cells: [String]) -> String in
            cells.enumerated().map { pad($0.element, widths[$0.offset]) }
                .joined(separator: "  ")
        }
        print(color("2", line(headers)))
        for row in rows {
            print(line(row).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression))
        }
    }
}

private extension Unicode.Scalar {
    /// East Asian Width が W か F か。表を揃えるのに足りる粒度で持つ。
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
