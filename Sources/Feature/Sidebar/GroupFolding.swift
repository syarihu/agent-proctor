import Foundation
import Combine

/// 見出しごとの折りたたみ。
///
/// 覚えておくのは**畳んであるものだけ**。開いているほうまで書くと、
/// 「手で開いた」と「まだ一度も触っていない」の区別が付かなくなる。
/// 新しく現れた見出しは開いた状態で出したいので、記録が無い = 開く、にしておく。
///
/// ただし**既定で畳んでおきたいものもある**ので、逆向きの集合 (`expanded`) も
/// 持っている。どちらを読むかは呼ぶ側が決める。
///
/// **同じ鍵が2つの側を行き来する。** リポジトリの見出しは、セッションが
/// 乗っているあいだは `collapsed` の側 (既定で開く)、セッションが無くなれば
/// `expanded` の側 (既定で畳む) として読まれる。だから**片側を手で動かしたら、
/// 逆側に残っている古い記録は捨てる**。残しておくと、側が入れ替わった瞬間に
/// 何日も前の操作が今の操作を上書きして、畳んだはずのものが勝手に開く
/// (逆も同じ)。捨てるのは同じ鍵の分だけで、`org:` や `wt:` の鍵は
/// 前置きで名前空間が分かれているため、そもそも逆側には居ない。
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
public final class GroupFolding: ObservableObject {
    /// 畳んである見出しの鍵
    @Published public private(set) var collapsed: Set<String>
    /// 既定で畳んでおくものの、開いてある鍵。
    ///
    /// collapsed と逆向きに持っているのは、worktree の一覧が既定で畳んであるから
    /// (手を挙げているセッションの下に、放置された作業場を全部並べたくない)。
    /// 同じ集合に混ぜると「記録が無い = 開く」の約束と衝突する
    @Published public private(set) var expanded: Set<String>

    /// 鍵の名前はリポジトリしか畳めなかった頃のまま。**変えると、それまで
    /// 畳んでいたものが次の起動で一斉に開く。** 名前の座りの悪さより、
    /// 手で畳んだ状態が消えないことを取る
    private static let key = "proctor_collapsed_repos"
    private static let expandedKey = "proctor_expanded_groups"

    public init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
        expanded = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
    }

    public func isCollapsed(_ group: String) -> Bool { collapsed.contains(group) }

    /// 既定で畳んであるものが開かれているか
    public func isExpanded(_ group: String) -> Bool { expanded.contains(group) }

    public func toggleExpanded(_ group: String) {
        if expanded.contains(group) {
            expanded.remove(group)
        } else {
            expanded.insert(group)
        }
        write(expanded.sorted(), forKey: Self.expandedKey)
        // 逆側に残っていた記録を捨てる (理由はこのクラスの説明)
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

    /// 逆側から同じ鍵を落とす。**入っていなければ何もしない** ——
    /// 書き込みは `objectWillChange` を飛ばすので、
    /// 見出しを1つ畳むたびに一覧をもう一度組み直すことになる
    private func forget(_ group: String, from side: inout Set<String>, forKey key: String) {
        guard side.contains(group) else { return }
        side.remove(group)
        write(side.sorted(), forKey: key)
    }

    /// **並べてから書く。** Set の順は毎回変わるので、そのまま書くと
    /// 中身が同じでも defaults の値が動いて差分を追えない
    private func write(_ keys: [String], forKey key: String) {
        UserDefaults.standard.set(keys, forKey: key)
    }
}
