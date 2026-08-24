/// セッションを動かしているエージェントの種別。
///
/// 台帳に入る値 ("claude" / "agy" / "codex") と、それを人に見せるときの
/// 名前と並び順をここにまとめる。**同じ対応表が3か所に散っていると、
/// エージェントを1つ足したときに片方だけ直して名前がずれる。**
///
/// 名前を `Localized` に置いていないのは、どれも製品の固有名で訳さないため。
public enum AgentKind {
    public static let claude = "claude"
    public static let antigravity = "agy"
    public static let codex = "codex"

    /// 一覧に出す名前。知らない値はそのまま出す
    /// (見覚えのない名前が出るほうが、Claude Code だと言い張られるより読める)
    public static func displayName(_ agent: String?) -> String {
        switch agent {
        case antigravity: return "Antigravity"
        case codex: return "Codex"
        case claude, nil, "": return "Claude Code"
        case let other?: return other
        }
    }

    /// 一覧に並べるときの順番。小さいほうが先
    public static func order(_ agent: String) -> Int {
        switch agent {
        case claude: return 0
        case antigravity: return 1
        case codex: return 2
        default: return 99
        }
    }

    /// モデル名からの当て推量。
    ///
    /// エージェントを名乗らない古い記録のための逃げ道で、
    /// 名乗りがあるならそちらが優先される
    public static func guessed(fromModel model: String) -> String? {
        let lower = model.lowercased()
        if lower.contains("gemini") { return antigravity }
        if lower.contains("gpt") || lower.contains("codex") { return codex }
        if lower.contains("claude") || lower.contains("sonnet")
            || lower.contains("opus") || lower.contains("haiku") {
            return claude
        }
        return nil
    }
}
