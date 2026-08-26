import Foundation

/// エージェントに渡す手引き1つぶん。
public struct SkillGuide: Encodable, Identifiable, Equatable {
    /// `proctor skill <id>` で引く名前
    public var id: String
    public var title: String
    public var summary: String
}

/// 同梱の手引きの置き場。
///
/// 本文を proctor が配るのは、各エージェントの設定に貼った写しが古びないようにするため。
/// 入口 (SKILL.md など) には「`proctor skill <名前>` を実行して従う」とだけ書いてもらえば、
/// 中身は proctor を新しくするだけで入れ替わる。
///
/// 文書はバンドルの .lproj に置いてあり、言語の選び方は文言と同じ (Localized)。
public enum SkillLibrary {
    /// 繋ぎ方の手引きは**エージェントごとに分けてある**。1つにまとめると、
    /// 読む側は自分に関係のない2つ分まで文脈に入れることになる
    static let setupIDs = ["setup-claude", "setup-agy", "setup-codex", "setup-other"]

    /// `proctor skill ls` に出る順。上から読む相手を選べるように並べる
    static let ids = ["worktree"] + setupIDs + ["setup-all"]

    /// 手引きの一覧
    public static var all: [SkillGuide] {
        ids.map {
            SkillGuide(id: $0,
                       title: Localized.text("skill.\($0).title"),
                       summary: Localized.text("skill.\($0).summary"))
        }
    }

    public static func guide(id: String) -> SkillGuide? {
        all.first { $0.id == id }
    }

    /// 手引きの本文。無い名前を渡されたら nil
    public static func body(id: String) -> String? {
        guard guide(id: id) != nil else { return nil }
        if id == "setup-all" { return everySetup() }
        return Localized.document("skill-\(id)")
    }

    /// 繋ぎ方をまとめて出す。
    ///
    /// **まとめた文書は持たない。** 持つと、エージェントごとの手引きと同じ内容が
    /// 2か所に並び、片方だけ直したときにずれる。読むときに繋いで返す。
    private static func everySetup() -> String? {
        let parts = setupIDs.compactMap { Localized.document("skill-\($0)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n---\n\n")
    }
}
