import Foundation
import Model
import Resources

/// 作業中の手順を書いた手引きの置き場。
///
/// 本文を proctor が配るのは、各エージェントの設定に貼った写しが古びないようにするため。
/// 入口 (SKILL.md など) には「`proctor skill <名前>` を実行して従う」とだけ書いてもらえば、
/// 中身は proctor を新しくするだけで入れ替わる。
///
/// 繋ぎ方 (hooks・statusLine) はここには置かない。あれは作業中に読むものではなく
/// 一度きりの設定なので、`proctor setup` (SetupLibrary) に分けてある。
///
/// 文書はバンドルの .lproj に置いてあり、言語の選び方は文言と同じ (Localized)。
public enum SkillLibrary {
    /// `proctor skill ls` に出る順
    static let ids = ["worktree"]

    /// 手引きの一覧
    public static var all: [Guide] {
        ids.map {
            Guide(id: $0,
                  title: Localized.text("skill.\($0).title"),
                  summary: Localized.text("skill.\($0).summary"))
        }
    }

    public static func guide(id: String) -> Guide? {
        all.first { $0.id == id }
    }

    /// 手引きの本文。無い名前を渡されたら nil
    public static func body(id: String) -> String? {
        guard guide(id: id) != nil else { return nil }
        return Localized.document("skill-\(id)")
    }
}
