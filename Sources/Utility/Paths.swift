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

    /// 取ってきた Organization のアイコンの置き場。
    ///
    /// キャッシュ用のディレクトリ (~/Library/Caches) ではなく台帳の隣に置くのは、
    /// proctor が残すものを1か所にまとめておくため。まるごと消しても、
    /// 次に一覧を開いたときに取り直すだけで済む
    public static var avatarsDir: URL { stateDir.appendingPathComponent("avatars") }

    /// 壊れた台帳の退避先。次の書き込みで消えてしまう前に原因を追えるようにする
    public static var brokenStateFile: URL {
        stateDir.appendingPathComponent("state.json.broken")
    }

    /// scripts/build-app.sh が組み立てるバンドルの名前。探すときもこれで揃える
    private static let appBundleName = "Agent Proctor.app"

    /// サイドバーの .app の探索。
    ///
    /// Homebrew 経由でのインストール時は Cellar 配下に配置されるため、/Applications 固定にはしない。
    ///
    /// 1. 環境変数 `PROCTOR_APP`: 明示指定がある場合はこれを優先する。
    /// 2. 実行ファイル自身が内包されている .app: 同梱 CLI (Contents/Helpers) から対となる .app を参照する。
    /// 3. /Applications / ~/Applications: 一般的な配置先。
    public static var appBundle: URL? {
        // 明示指定がある場合はそのパスのみを検証し、他候補へフォールバックしない。
        let override = ProcessInfo.processInfo.environment["PROCTOR_APP"]
        if let override, !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return isAppBundle(url) ? url : nil
        }

        var candidates: [URL] = []
        if let enclosing = enclosingAppBundle { candidates.append(enclosing) }
        candidates.append(URL(fileURLWithPath: "/Applications").appendingPathComponent(appBundleName))
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications").appendingPathComponent(appBundleName))
        return candidates.first { isAppBundle($0) }
    }

    /// 現在実行中のプロセスが内包されている .app バンドルの URL。バンドル外での実行時は nil。
    ///
    /// `appBundle` とは異なり、外部の /Applications 等を探索せず、
    /// 自身がバンドル内に存在するかどうかのみを判定する（開発ビルドでの誤判定防止）。
    ///
    /// CLI は Contents/Helpers、アプリ本体は Contents/MacOS に配置されるため、2階層上がバンドルルートとなる。
    /// argv[0] はシェル経由での実行時にコマンド名のみになる場合があるため executablePath を使用する。
    static var enclosingAppBundle: URL? {
        let executable = URL(fileURLWithPath:
            Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let bundle = executable.appendingPathComponent("../..").standardized
        return isAppBundle(bundle) ? bundle : nil
    }

    /// .app かどうか。ビルドディレクトリから直に走らせたときは
    /// ただのディレクトリになるので、拡張子と Info.plist の両方を見て弾く
    private static func isAppBundle(_ url: URL) -> Bool {
        guard url.pathExtension == "app" else { return false }
        return FileManager.default.fileExists(
            atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }
}
