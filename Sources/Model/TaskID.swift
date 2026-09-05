import Foundation
import Resources

/// CLI や端末操作で扱いやすいタスク識別子の生成ユーティリティ。
public enum TaskID {
    /// 英数字以外をハイフンに置換し小文字化する（シェルや AppleScript で安全に扱えるようにする）
    public static func slugify(_ text: String) -> String {
        let replaced = text.map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        let collapsed = String(replaced)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
            .lowercased()
        return collapsed.isEmpty ? "task" : collapsed
    }

    /// 既にある ID とぶつからないものを返す。
    public static func unique(base: String, taken tasks: [TaskRecord]) throws -> String {
        let used = Set(tasks.map(\.id))
        if !used.contains(base) { return base }
        for n in 2..<100 {
            let candidate = "\(base)-\(n)"
            if !used.contains(candidate) { return candidate }
        }
        throw ProctorError(Localized.text("error.task_id.exhausted"))
    }
}
