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
    static let bundleID = "com.googlecode.iterm2"

    /// オートメーションの許可が下りていないときに一度だけ知らせるための記録。
    /// 毎回出すと、許可しないと決めた人にとって邪魔にしかならない
    private static var permissionWarned = false

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
        guard let text = execute(source, interactive: false) else { return nil }
        let ids = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Set(ids)
    }

    /// いま見ているタブ (最前面のウィンドウの現在のセッション) の guid。
    ///
    /// ウィンドウが1つも無いときは空文字を返す。窓が無い状態で
    /// `current window` を辿ると AppleScript がエラーになり、
    /// 1秒ごとに標準エラーへ吐き続けることになる。
    ///
    /// 聞けなかったとき (iTerm2 が居ない・許可が無い) は nil。
    /// 「どこも見ていない」と区別できないと、印を消してよいか決められない。
    static func focusedSession() -> String? {
        let source = """
        tell application "iTerm2"
            if (count of windows) is 0 then return ""
            return id of current session of current tab of current window
        end tell
        """
        guard let text = execute(source, interactive: false) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard let text = execute(source, interactive: false) else { return nil }
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

    /// AppleScript の文字列リテラルに入れられる形にする。
    /// タスクIDは英数字と "-" に丸められているが、通り道は塞いでおく
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// - Parameter interactive: 人が押した操作かどうか。
    ///   背景色の取得や生存確認のような裏方の呼び出しでは、許可が無くても
    ///   黙って諦める。何もしていないのにダイアログが出てくるのは邪魔なだけで、
    ///   許可が要ることは「押したのに動かない」ときに伝えれば足りる
    private static func execute(_ source: String, interactive: Bool = true) -> String? {
        // iTerm2 が起きていないときに叩くと AppleScript が起動させてしまう。
        // サイドバーは iTerm2 に付き従うものなので、いないときは何もしない
        guard isItermRunning else { return nil }
        guard let script = NSAppleScript(source: source) else { return nil }

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
            alert.runModal()
        }
        // 許可以外の失敗はログに出るので、ここで重ねて騒がない
    }
}
