import Foundation
import Combine

/// リポジトリごとの折りたたみ。
///
/// 覚えておくのは**畳んであるものだけ**。開いているほうまで書くと、
/// 「手で開いた」と「まだ一度も触っていない」の区別が付かなくなる。
/// 新しく現れたリポジトリは開いた状態で出したいので、記録が無い = 開く、にしておく。
///
/// 鍵はリポジトリのパス。見出しに出している名前 (末尾の1つ) は
/// 別の場所にある同名のリポジトリとぶつかるので使わない。
///
/// 台帳から居なくなったリポジトリの分も消さずに残す。セッションが終われば
/// 台帳から消えるので、そこで忘れると「畳んでおいたのに次に開いたら広がっている」
/// ことになる。1件あたり数十バイトなので、溜まっても困らない。
@MainActor
final class RepoFolding: ObservableObject {
    /// 畳んであるリポジトリのパス
    @Published private(set) var collapsed: Set<String>

    private static let key = "proctor_collapsed_repos"

    init() {
        collapsed = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
    }

    func isCollapsed(_ repo: String) -> Bool { collapsed.contains(repo) }

    func toggle(_ repo: String) {
        if collapsed.contains(repo) {
            collapsed.remove(repo)
        } else {
            collapsed.insert(repo)
        }
        // 並べてから書く。Set の順は毎回変わるので、そのまま書くと
        // 中身が同じでも defaults の値が動いて差分を追えない
        UserDefaults.standard.set(collapsed.sorted(), forKey: Self.key)
    }
}
