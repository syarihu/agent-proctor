import AppKit
import CoreServices

/// iTerm2 のオートメーション権限（TCC）の確認と要求を行う。
///
/// 権限は macOS (TCC) が「バンドルID + コード署名」単位で管理する。
/// 拒否された場合、アプリ側から再度許可ダイアログを表示することはできず（errAEEventNotPermitted が返る）、
/// システム設定のプライバシー画面を開いてユーザーに手動変更を促す必要がある。
public enum AutomationPermission {
    public enum State: Sendable {
        /// 許可されている
        case granted
        /// 拒否されている（システム設定での手動許可が必要）
        case denied
        /// 未決定（次回要求時にダイアログ表示可能）
        case undecided
        /// iTerm2 が未起動（起動していないと権限の確認ができない）
        case targetNotRunning
        /// その他エラー
        case unknown
    }

    /// 現在の権限状態を取得する（ユーザーへのダイアログ表示は行わない）。
    /// ダイアログ待ちでブロックされないため、メインスレッドから呼び出し可能。
    public static func state() -> State {
        determine(askIfNeeded: false)
    }

    /// 権限が未決定の場合にユーザーへ許可を要求する。
    ///
    /// ユーザーの応答を待つ間ブロックされるため、メインスレッド外のバックグラウンドキューで実行する。
    /// Swift 並行処理の協調スレッドプール（コア数上限）を長時間ブロックして他のタスクが滞留するのを防ぐため、
    /// Task.detached ではなく DispatchQueue.global で実行する。
    public static func request() async -> State {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: determine(askIfNeeded: true))
            }
        }
    }

    private static func determine(askIfNeeded: Bool) -> State {
        // 許可は「誰が誰を操作するか」の組で持たれるので、相手を名指しで聞く
        var descriptor = AEAddressDesc()
        let created = ItermBridge.bundleID.withCString { name in
            AECreateDesc(typeApplicationBundleID, name, strlen(name), &descriptor)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&descriptor) }

        // typeWildCard を2つ渡しているのは「どの命令を送るか」を問わず聞くため。
        // 許可は命令ごとではなくアプリの組に対して下りる
        let status = AEDeterminePermissionToAutomateTarget(
            &descriptor, typeWildCard, typeWildCard, askIfNeeded)
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        // askIfNeeded が false のときだけ返る。true なら尋ねた結果が返る
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .undecided
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            // 分からないものを「許可されている」とも「iTerm2 が居ない」とも言わない
            return .unknown
        }
    }

    /// システム設定のオートメーションのページを開く。
    ///
    /// 開けるのはページまでで、その中の Agent Proctor の行までは指定できない。
    /// それでも「設定のどこかにあります」と文字で言うよりは近くまで運べる。
    @MainActor
    public static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
