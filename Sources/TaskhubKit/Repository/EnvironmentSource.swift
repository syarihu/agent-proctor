import Foundation

/// プロセスの環境から拾える情報。
public enum EnvironmentSource {
    /// iTerm2 のセッションID。ITERM_SESSION_ID は "w0t2p0:UUID" の形で入る。
    ///
    /// これを台帳に持っておくと、サイドバーから「そのセッションが開いているタブ」に
    /// 直接フォーカスできる。新しいタブを開き直さずに済む。
    ///
    /// ここで取れる UUID は iTerm2 の AppleScript から見える `id of session` と
    /// 同じ値 (どちらも PTYSession の guid) なので、そのまま突き合わせられる。
    public static func itermSessionID(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment["ITERM_SESSION_ID"], !raw.isEmpty else { return nil }
        return raw.components(separatedBy: ":").last
    }

    /// hooks から「このタスクを見ろ」と名指しされている場合の ID。
    public static func taskID(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let id = environment["TASKHUB_ID"], !id.isEmpty else { return nil }
        return id
    }

    public static func currentDirectory() -> String {
        FileManager.default.currentDirectoryPath
    }
}
