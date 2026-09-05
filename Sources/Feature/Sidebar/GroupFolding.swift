import Foundation
import Combine

/// 見出しごとの折りたたみ状態を管理・永続化するクラス。
///
/// 新規表示された見出しをデフォルトで展開状態にするため、折りたたまれたキーのみを `collapsed` 集合で保持する（未記録 = 展開）。
/// 一方、待機中 worktree などデフォルトで折りたたんでおくべき見出しのため、展開されたキーを管理する `expanded` 集合も保持する（未記録 = 折りたたみ）。
///
/// リポジトリの見出しは、セッションの有無により参照される集合（collapsed / expanded）が切り替わる。
/// 状態切り替え時に古い操作記録が意図せず反映されるのを防ぐため、片側をトグルした際は逆側の集合から同一キーを削除する。
///
/// キーには一意な識別子を使用する（リポジトリは絶対パス、Organization は `org:` 接頭辞付きのキー）。
@MainActor
public final class GroupFolding: ObservableObject {
    /// 折りたたまれている見出しキー（デフォルト展開グループ用）
    @Published public private(set) var collapsed: Set<String>
    /// 展開されている見出しキー（デフォルト折りたたみグループ用）
    @Published public private(set) var expanded: Set<String>

    /// 後方互換性維持のため既存の UserDefaults キー名を維持
    private static let key = "proctor_collapsed_repos"
    private static let expandedKey = "proctor_expanded_groups"

    public init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
        expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
    }

    public func isCollapsed(_ group: String) -> Bool { collapsed.contains(group) }

    /// デフォルト折りたたみグループが展開状態かを判定
    public func isExpanded(_ group: String) -> Bool { expanded.contains(group) }

    public func toggleExpanded(_ group: String) {
        if expanded.contains(group) {
            expanded.remove(group)
        } else {
            expanded.insert(group)
        }
        write(expanded.sorted(), forKey: Self.expandedKey)
        // 逆側の集合に残っている過去の記録を破棄
        forget(group, from: &collapsed, forKey: Self.key)
    }

    public func toggle(_ group: String) {
        if collapsed.contains(group) {
            collapsed.remove(group)
        } else {
            collapsed.insert(group)
        }
        write(collapsed.sorted(), forKey: Self.key)
        forget(group, from: &expanded, forKey: Self.expandedKey)
    }

    /// 逆側の集合から対象キーを削除する。不要な objectWillChange 発行と再描画を防ぐため、含まれている場合のみ実行する
    private func forget(_ group: String, from side: inout Set<String>, forKey key: String) {
        guard side.contains(group) else { return }
        side.remove(group)
        write(side.sorted(), forKey: key)
    }

    /// 配列をソートして永続化する（Set の非決定的な順序による不要な UserDefaults 変更差分を防止）
    private func write(_ keys: [String], forKey key: String) {
        UserDefaults.standard.set(keys, forKey: key)
    }
}
