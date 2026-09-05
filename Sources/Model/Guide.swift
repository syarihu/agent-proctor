import Foundation

/// エージェント向けガイド文書（スキルまたはセットアップ手順）のメタデータ。
/// `proctor skill` および `proctor setup` の一覧表示や取得で使用する。
public struct Guide: Encodable, Identifiable, Equatable {
    /// ガイドの識別子（サブコマンド引数として指定される名前）
    public var id: String
    public var title: String
    public var summary: String

    public init(id: String, title: String, summary: String) {
        self.id = id
        self.title = title
        self.summary = summary
    }
}
