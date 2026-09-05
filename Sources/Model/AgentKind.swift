/// セッションを動かしているエージェントの種別。
///
/// 台帳に入る値 ("claude" / "agy" / "codex") と、表示名・並び順を集約する。
/// エージェント追加時に定義が散逸して不整合を起こさないようにするため。
///
/// 名前を `Localized` に置いていないのは、製品の固有名であり翻訳対象外のため。
public enum AgentKind {
    public static let claude = "claude"
    public static let antigravity = "agy"
    public static let codex = "codex"

    /// 一覧に出す表示名。未知の種別はフォールバックとしてそのまま返す。
    public static func displayName(_ agent: String?) -> String {
        switch agent {
        case antigravity: return "Antigravity"
        case codex: return "Codex"
        case claude, nil, "": return "Claude Code"
        case let other?: return other
        }
    }

    /// 一覧に並べるときの優先順。小さい値が先頭。
    public static func order(_ agent: String) -> Int {
        switch agent {
        case claude: return 0
        case antigravity: return 1
        case codex: return 2
        default: return 99
        }
    }

    /// モデル名からの推測。エージェント種別が記録されていない過去ログ向けの後方互換処理。
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
