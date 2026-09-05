import Foundation
import Model
import Resources

/// proctor を繋ぐ手引きの置き場。
///
/// 繋ぎ方は環境によって違い、既に hooks や statusLine を使っている人の設定を
/// スクリプトで覆いきることはできない。だから proctor は設定を書き換えず、
/// **AI に読ませて実行させる指示**を配る。そこを吸収するのがエージェントの仕事。
///
/// `skill` と分けてあるのは、これが作業中に読む手順ではなく一度きりの設定だから。
public enum SetupLibrary {
    /// 繋ぎ方の手引きは**エージェントごとに分けてある**。1つにまとめると、
    /// 読む側は自分に関係のない相手の分まで文脈に入れることになる
    static let agentIDs = ["claude", "agy", "codex", "other"]

    /// `proctor setup ls` に出る順。上から読む相手を選べるように並べる
    static let ids = agentIDs + ["all"]

    /// 手引きの一覧
    public static var all: [Guide] {
        ids.map {
            Guide(id: $0,
                  title: Localized.text("setup.\($0).title"),
                  summary: Localized.text("setup.\($0).summary"))
        }
    }

    public static func guide(id: String) -> Guide? {
        all.first { $0.id == id }
    }

    /// 手引きの本文。無い名前を渡されたら nil
    public static func body(id: String) -> String? {
        guard guide(id: id) != nil else { return nil }
        if id == "all" { return everyAgent() }
        return Localized.document("setup-\(id)")
    }

    /// 繋ぎ方をまとめて出す。
    ///
    /// **まとめた文書は持たない。** 持つと、エージェントごとの手引きと同じ内容が
    /// 2か所に並び、片方だけ直したときにずれる。読むときに繋いで返す。
    private static func everyAgent() -> String? {
        let parts = agentIDs.compactMap { Localized.document("setup-\($0)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n---\n\n")
    }
}
