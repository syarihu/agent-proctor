import Foundation

/// タスク一覧のグループ化方式。
/// CLI の `proctor ls` はグループ化を行わないため、サイドバーおよび設定画面の UI 表現として DesignSystem で管理する。
public enum GroupingMode: String, CaseIterable, Sendable {
    /// リポジトリ単位
    case repository
    /// Organization 単位（配下にリポジトリをネスト表示）
    case organization
}
