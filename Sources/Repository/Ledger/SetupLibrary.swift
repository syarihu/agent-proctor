import Foundation
import Model
import Resources

/// proctor のセットアップガイドの取得窓口。
///
/// 環境に応じた指示文を提供する。エージェントごとの設定手順を個別またはまとめて出力する。
public enum SetupLibrary {
    /// エージェント種別の識別子一覧
    static let agentIDs = ["claude", "agy", "codex", "other"]

    /// `proctor setup ls` に出る順
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

    /// 手引きの本文。存在しない ID の場合は nil。
    public static func body(id: String) -> String? {
        guard guide(id: id) != nil else { return nil }
        if id == "all" { return everyAgent() }
        return Localized.document("setup-\(id)")
    }

    /// 全エージェント向けの手引きを連結して生成する。
    private static func everyAgent() -> String? {
        let parts = agentIDs.compactMap { Localized.document("setup-\($0)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n---\n\n")
    }
}
