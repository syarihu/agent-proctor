import Foundation

/// 台帳の置き場。リポジトリを横断して1つだけ持つ。
///
/// TASKHUB_STATE_DIR で差し替えられるのはテストのため。
/// 実運用では ~/.local/state/taskhub に固定される。
public enum Paths {
    public static let stateDir: URL = {
        let env = ProcessInfo.processInfo.environment["TASKHUB_STATE_DIR"]
        if let env, !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/taskhub")
    }()

    public static var stateFile: URL { stateDir.appendingPathComponent("state.json") }
    public static var lockFile: URL { stateDir.appendingPathComponent("state.lock") }
    public static var logsDir: URL { stateDir.appendingPathComponent("logs") }

    /// 壊れた台帳の退避先。次の書き込みで消えてしまう前に原因を追えるようにする
    public static var brokenStateFile: URL { stateDir.appendingPathComponent("state.json.broken") }
}

/// 利用者に見せて終了する種類のエラー。
///
/// これ以外の例外はプログラムの誤りなので、そのまま落ちてよい。
public struct TaskhubError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}
