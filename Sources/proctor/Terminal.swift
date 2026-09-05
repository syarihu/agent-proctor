import Foundation
import Model
import Resources

/// ターミナル出力用のフォーマッタおよび ANSI エスケープ処理
enum Terminal {
    /// 標準出力が端末の場合のみ ANSI カラーコードを付与する
    static func color(_ code: String, _ text: String) -> String {
        isatty(1) == 1 ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
    }

    /// 進捗メッセージを標準エラー出力に書き出す（標準出力の JSON や表出力を汚さないため）
    static func note(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// ステータス別の ANSI カラーコード
    static let statusColors: [String: String] = [
        TaskStatus.idle: "2",
        TaskStatus.running: "36",
        TaskStatus.waiting: "33",
        TaskStatus.done: "32",
        // 確認済みは視覚的優先度を下げるため薄暗い色にする
        TaskStatus.seen: "2",
        TaskStatus.failed: "31",
        TaskStatus.missing: "31",
    ]

    /// 状態に応じた（表示ラベル, ANSI 色コード）を返す
    static func style(_ status: String) -> (label: String, color: String) {
        ("\(TaskStatus.mark(status)) \(TaskStatus.label(status))",
         statusColors[status] ?? "0")
    }

    /// 差分件数を1行の表示文字列にフォーマットする。
    /// バイナリファイル等の行数を持たない変更は行数差分と明確に区別する。
    static func diff(_ counts: DiffCounts) -> String {
        var parts: [String] = []
        if counts.added > 0 { parts.append(color("32", "+\(counts.added)")) }
        if counts.removed > 0 { parts.append(color("31", "-\(counts.removed)")) }
        if counts.untracked > 0 { parts.append(color("36", "?\(counts.untracked)")) }
        // 行数が算出できないバイナリ変更は行数差分記号（+/-）と区別するため ~ を用いる
        if counts.binary > 0 { parts.append(color("33", "~\(counts.binary)")) }
        return parts.joined(separator: " ")
    }

    /// worktree の状態に応じた（表示ラベル, ANSI 色コード）を返す。
    /// 削除可否を誤認させないよう、セッション存在時はセッション件数を最優先で表示する。
    static func worktreeState(_ worktree: CollectedWorktree) -> (label: String, color: String) {
        if !worktree.sessions.isEmpty {
            // セッションが存在する場合は稼働中・終了後問わず保持中のセッション数を表示する
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

    /// 全角を2桁としてカウントした表示幅（ANSI エスケープシーケンスは除外）
    static func width(_ text: String) -> Int {
        let range = NSRange(text.startIndex..., in: text)
        let plain = ansiPattern.stringByReplacingMatches(
            in: text, range: range, withTemplate: "")
        return plain.unicodeScalars.reduce(0) { $0 + ($1.isEastAsianWide ? 2 : 1) }
    }

    static func pad(_ text: String, _ size: Int) -> String {
        text + String(repeating: " ", count: max(0, size - width(text)))
    }

    /// サブエージェント情報を1行の文字列にフォーマットする
    static func subagent(_ sub: CollectedSubagent, isLast: Bool) -> String {
        var parts = [color("35", sub.name)]
        if let label = sub.label { parts.append(label) }
        if let activity = sub.activity { parts.append(color("36", activity)) }
        parts.append(color("2", elapsed(sub.elapsedSeconds)))
        return color("2", "  \(isLast ? "└" : "├") ") + parts.joined(separator: " · ")
    }

    /// ターミナル用のテーブルを描画する。notes に指定した補足行は列幅計算から除外して各行の下に展開する。
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
    /// East Asian Width が Wide または Fullwidth かどうかを判定する
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
