import Foundation
import Model
import Resources

/// エージェント向け作業手順（スキル）のリポジトリ。
/// 文書本文を CLI から動的に提供することで、エージェント側設定の陳腐化を防ぐ。
/// 初期設定手順は `proctor setup`（SetupLibrary）として分離管理する。
public enum SkillLibrary {
    /// `proctor skill ls` の表示順
    static let ids = ["worktree"]

    /// 登録されているスキル一覧
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
