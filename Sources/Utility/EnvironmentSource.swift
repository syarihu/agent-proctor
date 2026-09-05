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

    /// Claude Code が全ての子プロセスへ渡すセッションID。
    ///
    /// 台帳の `TaskRecord.sessionId` と同じ値なので、エージェントが Bash から
    /// 何か叩いたとき、**自分がどの行なのかをそこから引ける**。
    /// hooks の payload が要らないのはこれがあるため。
    ///
    /// **サブエージェントの中から読んでも親の値が返る。** 子は親のプロセスから
    /// 環境ごと生えるので、子が名前を付けても付くのは親の行になる ——
    /// 一覧に出ているのは親の行なので、これは望ましい。
    ///
    /// 取れないとき (Claude Code 以外) は nil。
    public static func claudeSessionID(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let id = environment["CLAUDE_CODE_SESSION_ID"], !id.isEmpty else { return nil }
        return id
    }

    /// セッションを動かしているエージェント本体 (claude) のプロセスID。
    ///
    /// Claude Code が子プロセスへ CLAUDE_PID を渡してくれるので、それを使う。
    /// 親を辿って claude を探す手もあるが、hooks は `proctor _touch ... &` と
    /// バックグラウンドに投げられることがあり、フックのシェルが先に終わると
    /// 親子の鎖が切れて辿れなくなる。環境変数なら投げられても引き継がれる。
    ///
    /// 取れないとき (Antigravity など Claude Code 以外) は nil。
    /// 生死が分からないものは触らず、期限切れに任せる。
    public static func agentPID(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int? {
        guard let raw = environment["CLAUDE_PID"], let pid = Int(raw), pid > 0 else { return nil }
        return pid
    }

    /// hooks から「このタスクを見ろ」と名指しされている場合の ID。
    public static func taskID(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let id = environment["PROCTOR_ID"], !id.isEmpty else { return nil }
        return id
    }

    public static func currentDirectory() -> String {
        FileManager.default.currentDirectoryPath
    }

    public static func homeDirectory() -> String {
        NSHomeDirectory()
    }
}
