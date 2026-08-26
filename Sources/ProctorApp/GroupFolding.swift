import Foundation
import Combine

/// 見出しごとの折りたたみ。
///
/// 覚えておくのは**畳んであるものだけ**。開いているほうまで書くと、
/// 「手で開いた」と「まだ一度も触っていない」の区別が付かなくなる。
/// 新しく現れた見出しは開いた状態で出したいので、記録が無い = 開く、にしておく。
///
/// 鍵はその見出しを一意に指す文字列で、`TaskGrouping` が組み立てる。
/// リポジトリなら絶対パス、Organization なら `org:` を頭に付けたホストと持ち主。
/// 見出しに出している名前を使わないのは、別の場所にある同名のリポジトリと
/// ぶつかるため。前置きで種類を分けているのは、リポジトリのパスは必ず "/" で
/// 始まるので、両者が混ざっても取り違えないようにするため。
///
/// 台帳から居なくなった分も消さずに残す。セッションが終われば台帳から消えるので、
/// そこで忘れると「畳んでおいたのに次に開いたら広がっている」ことになる。
/// 1件あたり数十バイトなので、溜まっても困らない。
@MainActor
final class GroupFolding: ObservableObject {
    /// 畳んである見出しの鍵
    @Published private(set) var collapsed: Set<String>
    /// 既定で畳んでおくものの、開いてある鍵。
    ///
    /// collapsed と逆向きに持っているのは、worktree の一覧が既定で畳んであるから
    /// (手を挙げているセッションの下に、放置された作業場を全部並べたくない)。
    /// 同じ集合に混ぜると「記録が無い = 開く」の約束と衝突する
    @Published private(set) var expanded: Set<String>

    /// 鍵の名前はリポジトリしか畳めなかった頃のまま。**変えると、それまで
    /// 畳んでいたものが次の起動で一斉に開く。** 名前の座りの悪さより、
    /// 手で畳んだ状態が消えないことを取る
    private static let key = "proctor_collapsed_repos"
    private static let expandedKey = "proctor_expanded_groups"

    init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
        expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
    }

    func isCollapsed(_ group: String) -> Bool { collapsed.contains(group) }

    /// 既定で畳んであるものが開かれているか
    func isExpanded(_ group: String) -> Bool { expanded.contains(group) }

    func toggleExpanded(_ group: String) {
        if expanded.contains(group) {
            expanded.remove(group)
        } else {
            expanded.insert(group)
        }
        UserDefaults.standard.set(expanded.sorted(), forKey: Self.expandedKey)
    }

    func toggle(_ group: String) {
        if collapsed.contains(group) {
            collapsed.remove(group)
        } else {
            collapsed.insert(group)
        }
        // 並べてから書く。Set の順は毎回変わるので、そのまま書くと
        // 中身が同じでも defaults の値が動いて差分を追えない
        UserDefaults.standard.set(collapsed.sorted(), forKey: Self.key)
    }
}
