import AppKit
import CoreServices

/// iTerm2 を操作してよいか (オートメーションの許可) の窓口。
///
/// 許可を持っているのは macOS 側 (TCC) で、「バンドルID + コード署名」に紐づく。
/// 署名が変わると別人と見なされて許可は引き継がれない。
///
/// **アプリからできることは2つしかない。**
///
/// 1. **まだ決まっていないうちに尋ねる。** ダイアログを出せるのはこのときだけ
/// 2. **設定まで案内する。** 一度断られると macOS は聞き直してくれない。
///    `askIfNeeded` を立てて呼んでも、その場で errAEEventNotPermitted が返るだけで
///    ダイアログは出ない。記録を消す手立てはアプリ側には無く
///    (`tccutil` は人が端末から叩くもの)、設定へ送るのが唯一残された道になる
enum AutomationPermission {
    enum State {
        /// 許可されている
        case granted
        /// 断られている。もうダイアログは出せないので、設定へ送るしかない
        case denied
        /// まだ誰も決めていない。ダイアログを出せるのはこの状態のときだけ
        case undecided
        /// iTerm2 が起きていない。相手が居ないと許可の有無は確かめられない。
        /// 起こしてまで確かめには行かない
        case targetNotRunning
        /// 上のどれとも言えない失敗。**原因を1つに決めつけないために分けている**。
        /// 「iTerm2 が起動していません」と言い切ると、違う原因のときに
        /// iTerm2 を起こしに行かせて堂々巡りになる
        case unknown
    }

    /// いまの状態を読む。**尋ねない**ので、その場で返る。
    ///
    /// ヘッダが「メインスレッドで呼ぶな」と言っている理由は
    /// 「人に尋ねる間いくらでも待たされうるから」なので、
    /// 尋ねないこの経路はメインスレッドから呼んでよい。
    /// 尋ねるほうは `request()` を使うこと。
    static func state() -> State {
        determine(askIfNeeded: false)
    }

    /// まだ決まっていないときに尋ねる。決まっていれば、その答えがそのまま返る。
    ///
    /// **メインスレッドで呼んではいけない API なので、ここで外へ逃がす。**
    /// 人が答えるまで戻らず、その間メインスレッドを止めると
    /// サイドバーの描画も FocusWatcher の追従も一緒に止まってしまう。
    ///
    /// `Task.detached` ではなく GCD に投げているのは、逃がし先が
    /// **Swift 並行処理の協調プールだと幅が CPU のコア数で頭打ちになる**ため。
    /// この呼び出しは人が答えるまで戻らないので、プールの1本を
    /// 人間の注意力の長さだけ塞ぐことになり、同じプールを使う
    /// TaskStore の集計 (git を回す) がその間つかえる。
    /// GCD は塞がれた分だけスレッドを増やすので、待つならこちらが向いている。
    static func request() async -> State {
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
    static func openSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
        else { return }
        NSWorkspace.shared.open(url)
    }
}
