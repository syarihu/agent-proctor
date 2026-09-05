import Foundation

/// git の remote URL から読み取ったリポジトリの識別情報。
///
/// 一覧を Organization でまとめるときのキーになる。
/// ローカルのクローン先パスに依存せず、常に一意な識別を行うために remote URL を基準にする。
public struct RepoOrigin: Codable, Equatable, Sendable {
    /// ホスト名 ("github.com")。アイコン取得対象かどうかの判定に使用する
    public var host: String
    /// オーナー名。GitHub では user または organization の login 名
    public var owner: String
    /// リポジトリ名 (末尾の ".git" は除外)
    public var name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// アイコン取得に対応しているか (GitHub のみ)
    public var isGitHub: Bool { host == "github.com" }

    /// 折りたたみ状態を保持するためのキー。
    /// ホスト名を含め、GitHub の login 名が大文字小文字を区別しない仕様に合わせてオーナー名を小文字化する。
    public var groupKey: String { "\(host)/\(owner.lowercased())" }

    /// remote URL をパースする。パースできない場合は nil。
    /// ローカルパスはオーナーが存在しないため nil を返す。
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
            // scp 形式。先頭が "/" のパスは除外する。
            authority = String(trimmed[..<colon])
            path = String(trimmed[trimmed.index(after: colon)...])
        } else {
            return nil  // ローカルパス
        }

        // 認証情報やポート番号を除去し、ホスト名を小文字化する。
        // ホスト名は大小を区別しないため、表記揺れによるグループの分離を防ぐ。
        var host = authority
        if let at = host.lastIndex(of: "@") { host = String(host[host.index(after: at)...]) }
        if let port = host.firstIndex(of: ":") { host = String(host[..<port]) }
        host = host.lowercased()
        guard !host.isEmpty else { return nil }

        var segments = path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        // ディレクトリトラバーサル防止のため "." や ".." を含むものは除外する
        guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        var name = segments.removeLast()
        if name.hasSuffix(".git") { name.removeLast(4) }
        let owner = segments.joined(separator: "/")
        // .git を剥がした後の名前もチェックする
        guard !owner.isEmpty, !name.isEmpty, name != ".", name != ".." else { return nil }
        return RepoOrigin(host: host, owner: owner, name: name)
    }
}
