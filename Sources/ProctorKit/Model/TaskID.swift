import Foundation

/// タスクIDの決め方。
///
/// 人が打つものなので、ディレクトリ名をそのままではなく打ちやすい形に丸める。
/// 台帳の中で一意であればよく、意味は持たせない。
public enum TaskID {
    /// 英数字以外を "-" に潰して小文字にする。
    /// AppleScript やシェルに渡す通り道でもあるので、記号を残さない
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
