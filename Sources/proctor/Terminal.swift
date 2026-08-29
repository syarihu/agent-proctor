import Foundation
import ProctorKit

/// 端末に出すための道具。色も桁揃えも CLI だけの関心なので、
/// 共有の ProctorKit には置かない (アプリは SwiftUI で別に色を持っている)。
enum Terminal {
    /// 端末に出すときだけ色を付ける。パイプやファイルに流すときは素の文字にする。
    static func color(_ code: String, _ text: String) -> String {
        isatty(1) == 1 ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// 進捗の知らせ。--json の出力を汚さないよう stderr に出す。
    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// 状態ごとの ANSI 色。記号とラベルは ProctorKit の TaskStatus が持つ
    static let statusColors: [String: String] = [
        TaskStatus.idle: "2",
        TaskStatus.running: "36",
        TaskStatus.waiting: "33",
        TaskStatus.done: "32",
        // 見終わったものは役目を終えているので、色を引いて背景に馴染ませる
        TaskStatus.seen: "2",
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
        // バイナリは行数を言えないので、数え方が違うことが分かる別の記号にする。
        // `+`/`-` に混ぜると、何行変わったかを答えたように読めてしまう
        if counts.binary > 0 { parts.append(color("33", "~\(counts.binary)")) }
        return parts.joined(separator: " ")
    }

    /// worktree の状態を (表示用のラベル, ANSI の色) にする。
    ///
    /// セッションが乗っているかどうかを最優先で出す。使われている作業場を
    /// 「取り込み済み」と並べて見せると、消してよさそうに読めてしまう。
    static func worktreeState(_ worktree: CollectedWorktree) -> (label: String, color: String) {
        if !worktree.sessions.isEmpty {
            // **「実行中」とは言わない。** 終わったセッションもタブが開いている限り
            // 台帳に残るので、ここに数えるのは「その場所を誰かが開いている」まで。
            // 状態そのものは ls のほうで見るもので、ここで欲しいのは
            // 「手を出してよい場所か」の判断材料
            return (Localized.text("cli.worktree.state.sessions", worktree.sessions.count), "36")
        }
        if worktree.isMain { return (Localized.text("cli.worktree.state.main"), "0") }
        if worktree.isPrunable { return (Localized.text("cli.worktree.state.missing"), "31") }
        if worktree.isLocked { return (Localized.text("cli.worktree.state.locked"), "33") }
        if worktree.isRemovable { return (Localized.text("cli.worktree.state.removable"), "32") }
        if worktree.merged { return (Localized.text("cli.worktree.state.merged"), "33") }
        return (Localized.text("cli.worktree.state.idle"), "2")
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

    /// サブエージェント1体を1行に整える。
    ///
    /// アプリは幅が狭いので2行に分けているが、端末は横に余裕があるので
    /// 1行に畳む。出している中身は同じ (名前・何をさせているか・手元・経過)。
    static func subagent(_ sub: CollectedSubagent, isLast: Bool) -> String {
        var parts = [color("35", sub.name)]
        if let label = sub.label { parts.append(label) }
        if let activity = sub.activity { parts.append(color("36", activity)) }
        parts.append(color("2", elapsed(sub.elapsedSeconds)))
        return color("2", "  \(isLast ? "└" : "├") ") + parts.joined(separator: " · ")
    }

    /// 表を1つ書く。列の幅は中身から決める。
    ///
    /// - Parameter notes: 行ごとにぶら下げる補足 (サブエージェントの一覧)。
    ///   桁揃えの外側に出すので、長くても列幅を押し広げない
    static func table(headers: [String], rows: [[String]], notes: [[String]] = []) {
        let widths = (0..<headers.count).map { i in
            max(width(headers[i]), rows.map { width($0[i]) }.max() ?? 0)
        }
        let line = { (cells: [String]) -> String in
            cells.enumerated().map { pad($0.element, widths[$0.offset]) }
                .joined(separator: "  ")
        }
        print(color("2", line(headers)))
        for (index, row) in rows.enumerated() {
            print(line(row).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression))
            guard index < notes.count else { continue }
            for note in notes[index] { print(note) }
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
