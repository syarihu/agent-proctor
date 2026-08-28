import Foundation
import AppKit
import ProctorKit

/// iTerm2 との連携。
///
/// もともとは iTerm2 に同梱された Python から Python API を叩いていたが、
/// アプリに切り出すにあたって AppleScript に置き換えた。必要な操作は
/// すべて iTerm2 の AppleScript 辞書にある。
///
///   - `id of session` は PTYSession の guid で、シェルの ITERM_SESSION_ID の
///     ":" 以降と同じ値。だから台帳の itermSession とそのまま突き合わせられる
///   - `select` でタブにフォーカスできる
///   - `create tab with default profile command "..."` で新しいタブに命令を渡せる
///
/// NSAppleScript はスレッド安全ではないので、必ずメインスレッドから呼ぶ。
@MainActor
enum ItermBridge {
    // AutomationPermission がメインスレッド外から読むので隔離から外す。
    // 変わらない文字列なので、どのスレッドから読んでも困らない
    nonisolated static let bundleID = "com.googlecode.iterm2"

    /// オートメーションの許可が下りていないときに一度だけ知らせるための記録。
    /// 毎回出すと、許可しないと決めた人にとって邪魔にしかならない
    private static var permissionWarned = false

    /// 許可の答えが出ているか。**出るまで Apple Event を1つも投げない。**
    ///
    /// まだ誰も決めていないうちに投げると、macOS が同意ダイアログを出し、
    /// **答えるまで送信が戻らない。** 投げているのはメインスレッドなので、
    /// ランループごと止まってサイドバーもメニューバーの項目も描かれない。
    /// 「入れ直したら何も出てこない」の正体がこれで、答えたとたんに出てくる。
    ///
    /// 許可は「バンドルID + 署名の中身」に紐づくので、アドホック署名だと
    /// 入れ直すたびに未決へ戻る。証明書を作っていない環境 (Homebrew から
    /// 入れた場合) では毎回ここを通ることになる
    private static var permissionSettled = false
    /// いま尋ねている最中の問い合わせ。
    ///
    /// **旗ではなく問い合わせそのものを持つ。** 「尋ね中だから」と素通りさせると、
    /// 答えを待ったつもりの呼び出しが待たずに先へ進んでしまう。持っていれば、
    /// あとから来た者はその答えに相乗りできる
    private static var settling: Task<Void, Never>?

    /// 許可の答えが出るまで待つ。もう出ているなら何もしない。
    ///
    /// 尋ねる往復は AutomationPermission がメインスレッドの外へ逃がすので、
    /// 人が答えるまで待たされるのは向こうのスレッドだけで済む。
    static func settlePermission() async {
        guard !permissionSettled else { return }
        // 先客が居るなら、その答えを一緒に待つ。二重には尋ねない
        if let settling {
            await settling.value
            return
        }
        let asking = Task {
            let state = await AutomationPermission.request()
            // 相手が居ないうちは決めようがない。iTerm2 が起きてから聞き直す。
            // 断られた場合も「出た答え」なので通す (以後の送信はその場で
            // errAEEventNotPermitted が返るだけで、待たされることはない)
            permissionSettled = state != .targetNotRunning
        }
        // **待ちに入る前に預ける。** 待ってから預けると、その間に来た呼び出しが
        // 先客を見つけられず、同じ問い合わせをもう一度立ててしまう
        settling = asking
        await asking.value
        settling = nil
    }

    /// いま iTerm2 に開いているセッションの guid。
    ///
    /// 取得に失敗したときは nil を返す。空配列と区別できないと、
    /// 「一時的に取れなかった」ときに台帳を全部消してしまう。
    static func liveSessionIDs() -> Set<String>? {
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

    /// いま見ているタブ (最前面のウィンドウの現在のセッション) の guid と、その現在地。
    ///
    /// ウィンドウが1つも無いときは空の guid を返す。窓が無い状態で
    /// `current window` を辿ると AppleScript がエラーになり、
    /// 1秒ごとに標準エラーへ吐き続けることになる。
    ///
    /// 聞けなかったとき (iTerm2 が居ない・許可が無い) は nil。
    /// 「どこも見ていない」と区別できないと、印を消してよいか決められない。
    ///
    /// 現在地を同じ往復で取ってくる。1秒ごとに聞くものなので、
    /// Apple Event の往復を2つに増やしたくない。path は shell integration が
    /// 無くても iTerm2 が追っている
    static func focusedTab() -> (session: String, directory: String)? {
        let source = """
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            set s to current session of current tab of current window
            set p to ""
            try
                tell s to set p to (get variable named "path")
            end try
            return (id of s) & (character id 0) & p & (character id 0)
        end tell
        """
        guard let text = execute(source, interactive: false, reusable: true),
              let tabs = parseTabs(text) else { return nil }
        // 窓が無いときは空文字が返る。「聞けなかった」とは別物なので、
        // 空のまま (guid も現在地も無し) として返す
        return tabs.first ?? (session: "", directory: "")
    }

    /// 一番手前のウィンドウの枠を置き直す。
    ///
    /// AppleScript の `bounds` は {左, 上, 右, 下} で、原点は画面の左上。
    /// CGWindowList と同じ向きなので、読んだ枠をそのまま加工して渡せる。
    ///
    /// 動かすのは `current window`。サイドバーが追いかけているのも
    /// CGWindowList で最前面に出ている iTerm2 のウィンドウなので、同じものを指す。
    @discardableResult
    static func setCurrentWindowBounds(_ rect: CGRect) -> Bool {
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
    static var isItermFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
    }

    /// その guid のセッションが開いているタブにフォーカスする。
    /// 見つからなければ false を返すので、呼び出し側は開き直しに回れる。
    @discardableResult
    static func focus(sessionID: String) -> Bool {
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
    static func openTab(runningCommand command: String) -> Bool {
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
    static func sessionID(inDirectory path: String) -> String? {
        guard let tabs = openTabs(interactive: true) else { return nil }

        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var inside: String?
        for tab in tabs {
            guard !tab.directory.isEmpty else { continue }  // 居場所が読めないタブ
            if tab.directory == target { return tab.session }
            if inside == nil, tab.directory.hasPrefix(target + "/") { inside = tab.session }
        }
        return inside
    }

    /// いま開いている全タブの (guid, 現在地)。聞けなければ nil。
    ///
    /// 空配列と区別する。一時的に答えが返らなかっただけで
    /// 「どこにもタブが無い」と受け取ると、一覧から行がごっそり消える。
    ///
    /// **現在地が読めないタブも guid だけは返す。** ssh 越しなど、iTerm2 が
    /// そのタブの居場所を答えられないことがある。そこで組ごと捨てると、
    /// 台帳と guid で突き合わせる道 (TaskStore.visible) まで塞がる。
    ///
    /// 区切りは NUL。パスに絶対に現れない唯一の文字なので、名前にタブや改行を
    /// 含む worktree でも割れない (git の `--porcelain -z` と同じ考え方)。
    ///
    /// 区切りに `tab` と書かないこと。`tell application "iTerm2"` の中では
    /// `tab` はタブのクラスを指すので、区切りのつもりが文字列 "tab" になる。
    ///
    /// - Parameter interactive: 人が押した操作の一部か。裏方の呼び出しでは
    ///   許可が無くても黙って諦める (execute の説明を参照)
    static func openTabs(interactive: Bool) -> [(session: String, directory: String)]? {
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

    /// (guid, 現在地) の並びを読む。読めない形なら nil。
    ///
    /// **形が違うものを空配列にしない。** 空配列は「タブが1つも無い」という答えで、
    /// 絞り込む側はそれを信じて全部を隠す。答えが壊れていたのなら、
    /// 聞けなかったとき (nil) と同じ扱いにして絞り込みを見送らせる。
    ///
    /// パスは削らない。末尾の空白も名前の一部なので、整形すると別の場所を指す。
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
            // 表記違い (/tmp と /private/tmp) を吸収してから配る。
            // 受け取る側が毎回解決し直さずに済む。読めなかったタブは空のまま通す
            tabs.append((session: session,
                         directory: directory.isEmpty ? "" :
                            URL(fileURLWithPath: directory).resolvingSymlinksInPath().path))
        }
        return tabs
    }

    /// 新しいタブを開いて、その場所へ移動する。
    ///
    /// `command` でプログラムを渡さないのは、素のシェルが欲しいから。
    /// あれは指定したものをセッションの本体として起こすので、終われば
    /// タブごと消える。ここで開きたいのは「これから何か始める場所」なので、
    /// 普段どおりのシェルを立ち上げてから cd を打ち込む。
    @discardableResult
    static func openTab(inDirectory path: String) -> Bool {
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
    static func backgroundColor() -> NSColor? {
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

    static func activateIterm() {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID).first else { return }
        app.activate()
    }

    static var isItermRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    // MARK: -

    /// シェルに1語として渡せる形にする。
    ///
    /// **手で引用符を足さない。** worktree の名前に `'` が入っていても壊れないよう、
    /// 単引用符の中では閉じて・エスケープして・開き直す作法に従う
    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript の文字列リテラルに入れられる形にする。
    /// タスクIDは英数字と "-" に丸められているが、通り道は塞いでおく
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// 組み立て済みの AppleScript。**文面が変わらないものだけ覚える。**
    ///
    /// 見張りは1秒ごとに同じスクリプトを流すので、毎回作り直すとそのたびに
    /// 構文解析とコンパイルが走る。
    ///
    /// **窓の位置やセッションIDを埋め込むものは覚えない。** 呼ぶたびに文面が
    /// 変わるので、鍵にすると際限なく溜まる
    private static var compiled: [String: NSAppleScript] = [:]

    /// - Parameter interactive: 人が押した操作かどうか。
    ///   背景色の取得や生存確認のような裏方の呼び出しでは、許可が無くても
    ///   黙って諦める。何もしていないのにダイアログが出てくるのは邪魔なだけで、
    ///   許可が要ることは「押したのに動かない」ときに伝えれば足りる
    /// - Parameter reusable: 文面が呼び出しによらず一定か。
    ///   一定なものだけコンパイル結果を使い回す
    private static func execute(_ source: String, interactive: Bool = true,
                                reusable: Bool = false) -> String? {
        // iTerm2 が起きていないときに叩くと AppleScript が起動させてしまう。
        // サイドバーは iTerm2 に付き従うものなので、いないときは何もしない
        guard isItermRunning else { return nil }

        // **答えが出るまでは投げない** (理由は permissionSettled)。
        // 尋ねるのは裏に回して、ここは「聞けなかった」ことにして引き返す。
        // 呼ぶ側はどれも nil を受けたら前の値を保つ作りなので、
        // 答えが出たあとの周回で追いつく
        guard permissionSettled else {
            Task { await settlePermission() }
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
