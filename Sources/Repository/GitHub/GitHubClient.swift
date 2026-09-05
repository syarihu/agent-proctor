import Foundation
import Model
import Utility

/// GitHub への問い合わせ。gh (GitHub CLI) の呼び出しを集約する。
///
/// 認証情報の管理や Enterprise ホスト対応を gh に委ねるため、独自の API クライアントは持たずに CLI 経由で問い合わせる。
public enum GitHubClient {
    /// gh コマンドの実行パス。見つからない場合は nil。
    /// GUI アプリ起動時は環境変数 PATH が限定的なため、Homebrew の標準パス等を直接確認する。
    public static let executable: String? = {
        let known = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        if let found = known.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        let (ok, path) = ProcessRunner.capture(["which", "gh"])
        return ok && !path.isEmpty ? path : nil
    }()

    /// gh に資格情報が設定されているかどうか。
    ///
    /// `gh auth status` はネットワーク通信を伴いオフライン時に失敗するため、
    /// ローカルのトークン保持のみを素早く確認できる `gh auth token` を使用する。
    public static func hasCredentials() -> Bool {
        guard let gh = executable else { return false }
        return ProcessRunner.capture([gh, "auth", "token"]).ok
    }

    /// 指定ブランチに紐づく PR を取得する。
    ///
    /// `gh pr view` は PR が存在しない場合にも非0終了しエラーと判別できないため、
    /// 存在しない場合に正常終了（空リスト）する `gh pr list` を使用する。
    /// マージ済み PR も取得するため `--state all` を指定する。
    ///
    /// - Parameters:
    ///   - worktree: 実行対象リポジトリのパス
    ///   - branch: 照会対象のブランチ名
    public static func pullRequest(worktree: String, branch: String) -> PullRequestLookup {
        guard let gh = executable,
              !branch.isEmpty, branch != "HEAD", branch != "-" else { return .unavailable }
        let (ok, output) = ProcessRunner.capture(
            [gh, "pr", "list", "--head", branch, "--state", "all", "--limit", "1",
             "--json", "number,url,state,isDraft,title"],
            cwd: worktree, timeout: 15)
        guard ok, let data = output.data(using: .utf8),
              let found = try? JSONDecoder().decode([PullRequestRef].self, from: data) else {
            return .unavailable
        }
        return found.first.map(PullRequestLookup.found) ?? .absent
    }

    /// オーナーのアバター画像 URL を取得する。
    public static func avatarURL(owner: String, host: String = "github.com") -> String? {
        guard host == "github.com", let gh = executable else { return nil }
        let (ok, url) = ProcessRunner.capture(
            [gh, "api", "users/\(owner)", "--jq", ".avatar_url"])
        return ok && !url.isEmpty ? url : nil
    }

    /// アバター画像を一時ファイルにダウンロード後、アトミックに配置する。
    ///
    /// 同時ダウンロード時のファイル破損を防ぐため UUID 付与の一時ファイルに保存し、
    /// `replaceItemAt` でアトミックに置き換える。
    public static func downloadAvatar(from url: String, to destination: URL) -> Bool {
        let manager = FileManager.default
        try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                     withIntermediateDirectories: true)
        let partial = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).part")
        defer { try? manager.removeItem(at: partial) }

        // 過大なレスポンスによるリソース圧迫を防ぐため上限サイズ (8MB) を設定
        let (ok, _) = ProcessRunner.capture(
            ["curl", "-fsSL", "--max-time", "20", "--max-filesize", "8388608",
             "-o", partial.path, url])
        guard ok else { return false }

        // 存在確認から移動の間に他タスクが配置完了し moveItem が失敗した場合でも、後続の replaceItemAt でアトミックに置き換えるためフォールスルーする
        if !manager.fileExists(atPath: destination.path),
           (try? manager.moveItem(at: partial, to: destination)) != nil {
            return true
        }
        return (try? manager.replaceItemAt(destination, withItemAt: partial)) != nil
    }
}
