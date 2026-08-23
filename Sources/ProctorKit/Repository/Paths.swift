import Foundation

/// 物の置き場を答える窓口。台帳と、サイドバーの .app。
///
/// 台帳はリポジトリを横断して1つだけ持つ。
/// PROCTOR_STATE_DIR で差し替えられるのは試験のため。
/// 実運用では ~/.local/state/proctor に固定される。
public enum Paths {
    public static let stateDir: URL = {
        let env = ProcessInfo.processInfo.environment["PROCTOR_STATE_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/proctor")
    }()

    public static var stateFile: URL { stateDir.appendingPathComponent("state.json") }
    public static var lockFile: URL { stateDir.appendingPathComponent("state.lock") }
    public static var logsDir: URL { stateDir.appendingPathComponent("logs") }

    /// 壊れた台帳の退避先。次の書き込みで消えてしまう前に原因を追えるようにする
    public static var brokenStateFile: URL {
        stateDir.appendingPathComponent("state.json.broken")
    }

    /// scripts/install.sh が組み立てるバンドルの名前。探すときもこれで揃える
    private static let appBundleName = "Agent Proctor.app"

    /// サイドバーの .app の在り処。置かれ方が何通りかあるので順に当たる。
    ///
    /// /Applications 決め打ちにできないのは、Homebrew から入れると .app が Cellar の
    /// 下に置かれるため。formula は HOMEBREW_PREFIX の外に書けないので、
    /// /Applications にあるのはそこへの symlink か、あるいは何も無い。
    ///
    /// 1. `PROCTOR_APP` … 試験と、変な入れ方をしたときの逃げ道
    /// 2. 自分の居場所から2つ上 … CLI は Contents/Helpers にいるので、そこが .app。
    ///    これを先に見るのは「今動いている CLI と対の .app」を確実に指すから。
    ///    別の場所に入れ直したあと、古いほうを起動してしまうのを防ぐ。
    ///    symlink (~/bin/proctor や Homebrew の bin/proctor) 越しでも辿れるよう実体を見る
    /// 3. /Applications … .app だけ手で置いた・CLI を通さず起動したいとき
    /// 4. ~/Applications … 管理者権限なしで入れた場合
    public static var appBundle: URL? {
        var candidates: [URL] = []
        let override = ProcessInfo.processInfo.environment["PROCTOR_APP"]
        if let override, !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        candidates.append(executable.appendingPathComponent("../..").standardized)
        candidates.append(URL(fileURLWithPath: "/Applications").appendingPathComponent(appBundleName))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").appendingPathComponent(appBundleName))
        return candidates.first { isAppBundle($0) }
    }

    /// .app かどうか。ビルドディレクトリから直に走らせたときは 2 番目の候補が
    /// ただのディレクトリになるので、拡張子と Info.plist の両方を見て弾く
    private static func isAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }
}
