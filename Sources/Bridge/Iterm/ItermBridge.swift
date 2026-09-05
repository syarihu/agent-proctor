import Foundation
import AppKit
import Resources

/// iTerm2 との連携層。
///
/// iTerm2 の AppleScript を使用してセッションの識別・タブ選択・新規タブ生成を行う。
/// - `id of session` は PTYSession の GUID であり、環境変数 `ITERM_SESSION_ID` の値（コロン以降）と対応する。
/// - NSAppleScript はスレッドセーフではないため、すべての操作をメインスレッド（@MainActor）から実行する。
@MainActor
public enum ItermBridge {
    // AutomationPermission がメインスレッド外から読むので隔離から外す。
    // 変わらない文字列なので、どのスレッドから読んでも困らない
    nonisolated public static let bundleID = "com.googlecode.iterm2"

    /// オートメーション権限未許可を通知済みかどうかのフラグ（警告の重複表示防止用）
    private static var permissionWarned = false

    /// 権限状態が確定しているか。
    /// 未決定のままメインスレッドから同期で Apple Event を送信するとダイアログ待ちで
    /// UI とタイマーが停止するため、確定するまで送信を抑止する。
    private static var permissionSettled = false
    /// 実行中の権限問い合わせタスク（重複要求の相乗り用）
    private static var settling: Task<Void, Never>?

    /// 権限状態が確定するまで待機する。確定済みの場合は即座に戻る。
    public static func settlePermission() async {
        guard !permissionSettled else { return }
        // 先行タスクがある場合はその完了を待つ
        if let settling {
            await settling.value
            return
        }
        let asking = Task {
            switch await AutomationPermission.request() {
            case .granted, .denied:
                // 拒否された場合も以降は待機せず即座に errAEEventNotPermitted が返るため確定扱いとする
                permissionSettled = true
            case .unknown:
                // 不明な場合も待機は発生しないため確定扱いとする
                permissionSettled = true
            case .undecided, .targetNotRunning:
                // 未決定または未起動時は次回ダイアログ待ちになるリスクがあるため未確定のまま維持する
                permissionSettled = false
            }
        }
        // 重複問い合わせを防ぐため、待機前に保持する
        settling = asking
        await asking.value
        settling = nil
    }

    /// いま iTerm2 に開いているセッションの guid。
    ///
    /// 取得に失敗したときは nil を返す。空配列と区別できないと、
    /// 「一時的に取れなかった」ときに台帳を全部消してしまう。
    public static func liveSessionIDs() -> Set<String>? {
        let source = """
        tell application "iTerm2"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set out to out & (id of s) & linefeed
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        guard let text = execute(source, interactive: false, reusable: true) else { return nil }
        let ids = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    /// いま見ているタブ (最前面のウィンドウの現在のセッション) の guid と、その現在地、
    /// そして開いている全セッションのタブ番号 (⌘N の N)。
    ///
    /// ウィンドウが1つも無いときは空の guid を返す。窓が無い状態で
    /// `current window` を辿ると AppleScript がエラーになり、
    /// 1秒ごとに標準エラーへ吐き続けることになる。
    ///
    /// 聞けなかったとき (iTerm2 が居ない・許可が無い) は nil。
    /// 「どこも見ていない」と区別できないと、印を消してよいか決められない。
    ///
    /// 現在地とタブ番号を同じ往復で取ってくる。1秒ごとに聞くものなので、
    /// Apple Event の往復を2つに増やしたくない。path は shell integration が
    /// 無くても iTerm2 が追っている。
    ///
    /// タブ番号の取得と最適化方針:
    /// iTerm2 の AppleScript では `index of tab` は未実装でエラー（-1728）となり、
    /// `tab.id` や `ITERM_SESSION_ID` は作成順序の固定値で並び順の位置を表さないため、
    /// `tabs of window` の階層から毎回算出して特定する。
    ///
    /// また、AppleScript 内でプロパティ参照ごとに発生する Apple Event（1件あたり約17ms）による
    /// メインスレッドのブロックを最小限にするため、以下の最適化を行っている:
    /// - `id of sessions of tabs of windows` で全階層を一括取得し、往復回数を最小化する。
    /// - 中間変数への代入を避け、直接プロパティを取得して不要なイベント送信を防ぐ。
    /// - `tell <指定子> to ...` で直接プロパティにアクセスする。
    ///
    /// - Parameter withTabNumbers: タブ番号を取得するか。無効時は不要なイベント送信を省くためクエリから除外する。
    public static func focusedTab(withTabNumbers: Bool)
        -> (session: String, directory: String, tabNumbers: [String: Int])? {
        var source = """
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            set p to ""
            try
                tell current session of current tab of current window ¬
                    to set p to (get variable named "path")
            end try
            set out to (id of current session of current tab of current window) ¬
                & (character id 0) & p & (character id 0)
        """
        if withTabNumbers {
            source += """

            set grid to id of sessions of tabs of windows
            repeat with win in grid
                set n to 0
                repeat with row in win
                    set n to n + 1
                    repeat with g in row
                        set out to out & (g as text) & (character id 0) ¬
                            & (n as text) & (character id 0)
                    end repeat
                end repeat
            end repeat
            """
        }
        source += """

            return out
        end tell
        """
        guard let text = execute(source, interactive: false, reusable: true) else { return nil }
        return parseFocus(text)
    }

    /// focusedTab の応答文字列をパースする。パースに失敗した場合は nil を返す。
    /// 不正なフォーマットを空配列・空文字として扱うと「ウィンドウが存在しない」と誤認して
    /// 表示が消えてしまうため、取得失敗時と同様に nil を返して前の状態を維持させる。
    private static func parseFocus(_ text: String)
        -> (session: String, directory: String, tabNumbers: [String: Int])? {
        // 窓が1つも無ければ空文字。これは「どこも見ていない」という確かな答え
        if text.isEmpty { return (session: "", directory: "", tabNumbers: [:]) }
        guard text.contains("\0") else { return nil }

        var fields = text.components(separatedBy: "\0")
        // 各組の末尾にも区切りを打っているので、最後に空の余りが1つ出る
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count >= 2, fields.count % 2 == 0 else { return nil }

        var numbers: [String: Int] = [:]
        for index in stride(from: 2, to: fields.count, by: 2) {
            let session = fields[index]
            guard !session.isEmpty, let number = Int(fields[index + 1]) else { continue }
            // 分割ペインは1つのタブに複数のセッションが乗る。鍵はタブに効くので、
            // 同じタブのセッションはどれも同じ番号でよい
            numbers[session] = number
        }
        return (session: fields[0],
                directory: fields[1].isEmpty ? "" :
                    URL(fileURLWithPath: fields[1]).resolvingSymlinksInPath().path,
                tabNumbers: numbers)
    }

    /// 一番手前のウィンドウの枠を置き直す。
    ///
    /// AppleScript の `bounds` は {左, 上, 右, 下} で、原点は画面の左上。
    /// CGWindowList と同じ向きなので、読んだ枠をそのまま加工して渡せる。
    ///
    /// 動かすのは `current window`。サイドバーが追いかけているのも
    /// CGWindowList で最前面に出ている iTerm2 のウィンドウなので、同じものを指す。
    @discardableResult
    public static func setCurrentWindowBounds(_ rect: CGRect) -> Bool {
        let source = """
        tell application "iTerm2"
            if (count of windows) is 0 then return "none"
            set bounds of current window to \
        {\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.maxX)), \(Int(rect.maxY))}
            return "ok"
        end tell
        """
        // 人が押した操作ではないので、許可が無いときに騒がない
        return execute(source, interactive: false)?.hasPrefix("ok") == true
    }

    /// iTerm2 が最前面か。確認済みの印を付けてよいかの判定に使う。
    /// NSWorkspace を見るだけなのでオートメーションの許可は要らない
    public static var isItermFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// その guid のセッションが開いているタブにフォーカスする。
    /// 見つからなければ false を返すので、呼び出し側は開き直しに回れる。
    @discardableResult
    public static func focus(sessionID: String) -> Bool {
        let source = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if (id of s) is "\(escape(sessionID))" then
                            select w
                            select t
                            select s
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "notfound"
        end tell
        """
        guard execute(source)?.hasPrefix("ok") == true else { return false }
        activateIterm()
        return true
    }

    /// 新しいタブでコマンドを走らせる。ウィンドウが無ければ作る。
    @discardableResult
    public static func openTab(runningCommand command: String) -> Bool {
        let source = """
        tell application "iTerm2"
            if (count of windows) is 0 then
                create window with default profile command "\(escape(command))"
            else
                tell current window
                    create tab with default profile command "\(escape(command))"
                end tell
            end if
            return "ok"
        end tell
        """
        guard execute(source)?.hasPrefix("ok") == true else { return false }
        activateIterm()
        return true
    }

    /// その場所を開いているタブの guid。無ければ nil。
    ///
    /// 台帳に載るのはエージェントのセッションだけなので、cd しただけのタブは
    /// proctor から見えない。iTerm2 は shell integration が無くてもタブの現在地を
    /// 追っているので、そちらに聞く。
    ///
    /// その worktree の中に降りているタブも同じ場所とみなす (src/ で作業していた、など)。
    /// 逆向き (親にいるタブ) は当たらないので、worktree を本体の中に置いていても
    /// 本体のタブを掴むことはない。ぴったり同じ場所に居るタブがあれば、そちらを優先する。
    public static func sessionID(inDirectory path: String) -> String? {
        guard let tabs = openTabs(interactive: true) else { return nil }

        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var inside: String?
        for tab in tabs {
            guard !tab.directory.isEmpty else { continue }  // 作業ディレクトリが取得できないタブ
            if tab.directory == target { return tab.session }
            if inside == nil, tab.directory.hasPrefix(target + "/") { inside = tab.session }
        }
        return inside
    }

    /// 開いている全タブの (guid, 現在地) の一覧を取得する。取得失敗時は nil を返す。
    ///
    /// 一時的な取得失敗で全タスクが非表示になるのを防ぐため、空配列と nil を明確に区別する。
    /// 現在地が取得できないタブ（リモート接続等）であっても、台帳とのセッションID突合のため guid は保持して返す。
    /// パスに空白や特殊文字が含まれる場合でも正しく分割できるよう、区切り文字には NUL（\0）を使用する。
    ///
    /// - Parameter interactive: ユーザー操作起因の呼び出しフラグ。
    public static func openTabs(interactive: Bool) -> [(session: String, directory: String)]? {
        let source = """
        tell application "iTerm2"
            set out to ""
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        set p to ""
                        try
                            tell s to set p to (get variable named "path")
                        end try
                        set out to out & (id of s) & (character id 0) & p & (character id 0)
                    end repeat
                end repeat
            end repeat
            return out
        end tell
        """
        guard let text = execute(source, interactive: interactive, reusable: true) else {
            return nil
        }
        return parseTabs(text)
    }

    /// (guid, 現在地) の応答文字列をパースする。パースに失敗した場合は nil を返す。
    /// パース異常を空配列として扱うと全タブが閉じられたと誤認するため、nil を返してフィルタリングを見送らせる。
    private static func parseTabs(_ text: String) -> [(session: String, directory: String)]? {
        // 窓が1つも無ければ空文字。これは「タブが無い」という確かな答え
        if text.isEmpty { return [] }
        guard text.contains("\0") else { return nil }

        var fields = text.components(separatedBy: "\0")
        // 各組の末尾にも区切りを打っているので、最後に空の余りが1つ出る
        if fields.last?.isEmpty == true { fields.removeLast() }
        guard fields.count % 2 == 0 else { return nil }

        var tabs: [(session: String, directory: String)] = []
        for index in stride(from: 0, to: fields.count, by: 2) {
            let session = fields[index]
            guard !session.isEmpty else { continue }
            let directory = fields[index + 1]
            // パス表記の差異（/tmp と /private/tmp など）を解決して正規化する
            tabs.append((session: session,
                         directory: directory.isEmpty ? "" :
                            URL(fileURLWithPath: directory).resolvingSymlinksInPath().path))
        }
        return tabs
    }

    /// 新しいタブを開いて指定ディレクトリへ移動する。
    ///
    /// コマンド引数として指定するとプロセス終了時にタブが閉じてしまうため、
    /// デフォルトプロファイルでシェルを起動した上で cd コマンドを送信する。
    @discardableResult
    public static func openTab(inDirectory path: String) -> Bool {
        let command = "cd \(shellQuoted(path))"
        let source = """
        tell application "iTerm2"
            if (count of windows) is 0 then
                set t to (create window with default profile)
                tell current session of current tab of t
                    write text "\(escape(command))"
                end tell
            else
                tell current window
                    set t to (create tab with default profile)
                    tell current session of t
                        write text "\(escape(command))"
                    end tell
                end tell
            end if
            return "ok"
        end tell
        """
        guard execute(source)?.hasPrefix("ok") == true else { return false }
        activateIterm()
        return true
    }

    /// いま使われているプロファイルの背景色。サイドバーの下地を端末に馴染ませる。
    /// 取れなければ nil を返し、呼び出し側はシステムの色に任せる。
    public static func backgroundColor() -> NSColor? {
        let source = """
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            tell current session of current tab of current window
                set c to background color
                return ((item 1 of c) as text) & "," & ((item 2 of c) as text) ¬
                    & "," & ((item 3 of c) as text)
            end tell
        end tell
        """
        guard let text = execute(source, interactive: false, reusable: true) else { return nil }
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3 else { return nil }
        // AppleScript の RGB は 0..65535
        return NSColor(srgbRed: parts[0] / 65535, green: parts[1] / 65535,
                       blue: parts[2] / 65535, alpha: 1)
    }

    public static func activateIterm() {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate()
    }

    public static var isItermRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: -

    /// シェルの引数として安全に解釈されるようシングルクォートでエスケープする。
    /// 文字列自体にシングルクォートが含まれる場合も壊れないよう標準のエスケープ処理を行う。
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript の文字列リテラルに入れられる形にする。
    /// タスクIDは英数字と "-" に丸められているが、通り道は塞いでおく
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// コンパイル済み AppleScript のキャッシュ。
    ///
    /// ポーリング時の構文解析・コンパイル負荷を避けるため、文面が不変のスクリプトのみキャッシュする。
    /// 座標やセッションIDなど呼び出しごとに変化するパラメータを含むスクリプトはキャッシュしない。
    private static var compiled: [String: NSAppleScript] = [:]

    /// - Parameter interactive: ユーザー操作起因の呼び出しフラグ。
    ///   定期ポーリング等のバックグラウンド処理では、権限未取得でも警告ダイアログを表示せず中断する。
    /// - Parameter reusable: 文面が不変でコンパイル結果をキャッシュ可能かどうか。
    private static func execute(_ source: String, interactive: Bool = true,
                                reusable: Bool = false) -> String? {
        // iTerm2 未起動時に AppleScript を実行すると意図せず起動してしまうためガードする
        guard isItermRunning else { return nil }

        // 権限確定前はメインスレッド停止を避けるため実行せず、非同期で権限要求を開始する
        guard permissionSettled else {
            if settling == nil { Task { await settlePermission() } }
            return nil
        }

        let script: NSAppleScript
        if reusable, let cached = compiled[source] {
            script = cached
        } else {
            guard let made = NSAppleScript(source: source) else { return nil }
            if reusable { compiled[source] = made }
            script = made
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            // 黙って諦めると「押しても動かない」理由を追う手掛かりが消える。
            // 人に見せるかどうかとは別に、記録だけは必ず残す
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            FileHandle.standardError.write(
                Data("proctor: iTerm2: [\(code)] \(message)\n".utf8))
            if interactive { report(code: code) }
            return nil
        }
        return result.stringValue ?? ""
    }

    private static func report(code: Int) {
        // -1743: オートメーションが許可されていない
        if code == -1743, !permissionWarned {
            permissionWarned = true
            let alert = NSAlert()
            alert.messageText = Localized.text("app.alert.automation.title")
            alert.informativeText = Localized.text("app.alert.automation.body")
            alert.alertStyle = .warning
            // 場所を文字で伝えるだけだと、設定のどこにあるかを探すところから始まる。
            // ここまで来た時点で断られた記録があり、聞き直させる手立ては無いので
            // (詳しくは AutomationPermission)、せめて開くところまでは引き受ける
            alert.addButton(withTitle: Localized.text("app.action.open_settings"))
            alert.addButton(withTitle: Localized.text("app.alert.automation.later"))
            if alert.runModal() == .alertFirstButtonReturn {
                AutomationPermission.openSettings()
            }
        }
        // 許可以外の失敗はログに出るので、ここで重ねて騒がない
    }
}
