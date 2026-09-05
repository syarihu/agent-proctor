import Foundation

/// git の remote URL から読み取った「どこの誰のリポジトリか」。
///
/// 一覧を Organization でまとめるときの鍵になる。
///
/// **置き場所のパス (`~/git/syarihu/…` の `syarihu`) を使わないのは、
/// どこに clone するかが人それぞれだから。** 同じ組織のリポジトリを別の場所に
/// 置いていれば別の組織として並ぶし、worktree を別のところに切っていれば
/// 本体とも離れてしまう。remote URL なら、どこに置いてあっても同じ答えになる。
/// (中身は文字列3つなので、スレッドを跨いで渡しても困らない。
/// 表示側が別のスレッドへ持ち出すため `Sendable` を明示しておく)
public struct RepoOrigin: Codable, Equatable, Sendable {
    /// ホスト名 ("github.com")。アイコンを取りに行ってよい相手かの判断に使う
    public var host: String
    /// 持ち主。GitHub では user か organization の login 名。
    /// グループが入れ子になる置き方 (GitLab) では "group/subgroup" になる
    public var owner: String
    /// リポジトリ名 (末尾の ".git" は落としてある)
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// アイコンを引ける相手か。gh で引けるのは GitHub だけ
    public var isGitHub: Bool { host == "github.com" }

    /// 折りたたみを覚えるための鍵。ホストまで含めるのは、別のホストに
    /// 同じ名前の組織があったときに畳み方が連動してしまわないようにするため。
    ///
    /// **持ち主も小文字で並べる。** GitHub の login は大小を区別しないので、
    /// `syarihu` と `Syarihu` を別の見出しに分けてしまうと、同じ人の
    /// リポジトリが2つの組織に散る (見出しに出す名前のほうは原文を使う)
    public var groupKey: String { "\(host)/\(owner.lowercased())" }

    /// remote URL を読む。読めなければ nil。
    ///
    /// git が受け付ける書き方は3通りある。
    ///
    /// | 書き方 | 例 |
    /// | --- | --- |
    /// | scp 風 | `git@github.com:owner/repo.git` |
    /// | URL | `ssh://git@github.com/owner/repo.git`, `https://github.com/owner/repo.git` |
    /// | ローカルパス | `/srv/git/repo.git` |
    ///
    /// ローカルパスには持ち主がいないので nil を返す。持ち主が分からないものを
    /// 無理に名付けると、無関係なリポジトリが1つの見出しの下に集まってしまう。
    public static func parse(_ remote: String) -> RepoOrigin? {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let authority: String
        let path: String
        if let scheme = trimmed.range(of: "://") {
            let rest = trimmed[scheme.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            authority = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
        } else if !trimmed.hasPrefix("/"), let colon = trimmed.firstIndex(of: ":") {
            // scp 風。":" の手前がホスト、後ろがパス。
            // 先頭が "/" のものを先に弾いておかないと、パスに ":" を含む
            // ローカルリポジトリをホスト名として読んでしまう
            authority = String(trimmed[..<colon])
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil  // ローカルパス
        }

        // "git@" や "user:token@" を落とし、ポート番号も落とす。
        // 認証情報を残すと、同じホストでも書き方の違いで別の組織に見える。
        //
        // **小文字に揃えるのは、ホスト名が大小を区別しないから。** 手で
        // "GitHub.com" と打った remote があると、揃えていなければ `isGitHub` が
        // 外れてアイコンが出ず、見出しも別の組織として分かれてしまう
        var host = authority
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        host = host.lowercased()
        guard !host.isEmpty else { return nil }

        var segments = path.split(separator: "/").map(String.init)
        // 持ち主とリポジトリ名で最低2つ。1つしか無いものは持ち主が居ない
        guard segments.count >= 2 else { return nil }
        // **"." や ".." が混じったものは持ち主として扱わない。** 名前ではなく
        // 場所を指す語なので、これを持ち主だと思って何かの鍵に使うと、
        // 使った先で置き場の外に出る。ここで落としておく
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        var name = segments.removeLast()
        if name.hasSuffix(".git") { name.removeLast(4) }
        let owner = segments.joined(separator: "/")
        // 名前のほうは `.git` を剥がしたあとにもう一度見る。上の門は剥がす前の
        // セグメントを見ているので、`.../...git` のような書き方だと
        // **通り抜けたあとに "." や ".." が出来上がる**
        guard !owner.isEmpty, !name.isEmpty, name != ".", name != ".." else { return nil }
        return RepoOrigin(host: host, owner: owner, name: name)
    }
}
