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
/// **本文を proctor が配る**のは、各エージェントの設定に貼った写しが古びないようにするため。
/// 入口 (SKILL.md など) には「`proctor skill worktree` を実行して従う」とだけ書いてもらえば、
/// 中身は proctor を新しくするだけで入れ替わる。
///
/// 文書はバンドルの .lproj に置いてあり、言語の選び方は文言と同じ (Localized)。
public enum SkillLibrary {
    /// 手引きの一覧
    public static var all: [SkillGuide] {
        [SkillGuide(id: "worktree",
                    title: Localized.text("skill.worktree.title"),
                    summary: Localized.text("skill.worktree.summary"))]
    }

    public static func guide(id: String) -> SkillGuide? {
        all.first { $0.id == id }
    }

    /// 手引きの本文。無い名前を渡されたら nil
    public static func body(id: String) -> String? {
        guard guide(id: id) != nil else { return nil }
        return Localized.document("skill-\(id)")
    }
}
