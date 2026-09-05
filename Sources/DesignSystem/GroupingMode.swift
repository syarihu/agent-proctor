import Foundation

/// 一覧のまとめ方。
///
/// 表示の都合なので DesignSystem に置く。
/// CLI の `proctor ls` は一覧をまとめずに並べるので、この語彙が要るのはサイドバーと設定画面になる。
public enum GroupingMode: String, CaseIterable, Sendable {
    /// リポジトリごと
    case repository
    /// Organization ごと。その下にリポジトリがぶら下がる
    case organization
}
