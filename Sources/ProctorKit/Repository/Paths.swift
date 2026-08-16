import Foundation

/// 台帳の置き場。リポジトリを横断して1つだけ持つ。
///
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
}
