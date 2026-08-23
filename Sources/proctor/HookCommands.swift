import Foundation
import ProctorKit

/// hooks と statusline から呼ばれるコマンド。人が打つものではない。
/// 判断は UseCase 側が持ち、ここは受け渡しだけにする。

/// 記録した状態を stdout に返す。呼び出し側が「結局どうなったか」を使えるようにする
/// (タブの色を変えるなど)。判断をシェル側に写すと、片方だけ直したときに食い違う。
func cmdTouch(_ args: Args) throws -> Int32 {
    let accepted = TaskStatus.fromHooks + ["notification"]
    var status = try args.require(
        0, Localized.text("cli.arg.status", accepted.joined(separator: "|")))
    guard accepted.contains(status) else {
        throw ProctorError(Localized.text(
            "cli.error.invalid_status", accepted.joined(separator: "/"), status))
    }

    let payload = HookPayload.fromStandardInput()

    // notification は権限確認でもアイドル通知でも飛んでくる。
    // どちらなのかの判断は UseCase が持つ
    if status == "notification" {
        guard let resolved = RecordHookEvent.resolveNotification(payload) else {
            if args.has("--json") { print("{}") }
            return 0  // アイドル通知。何も出さないことで「変えない」を伝える
        }
        status = resolved
    }
    // 返すのは**台帳に記録した状態**。届いた状態とは限らない
    // (子がまだ走っているセッションは、done が来ても実行中のまま記録する)。
    // 呼び出し側がタブの色をこれで決めるので、ここで届いた値をそのまま返すと
    // 一覧は実行中なのにタブだけ緑、という食い違いが起きる。
    //
    // ただし**食い違いが消えるわけではない**。保留していた終わりを確定させるのは
    // SubagentStop で、あちらは何も返さない。今度はタブだけ実行中のまま残る。
    // 向きを変えて先送りしているだけなので、タブまで揃えたいなら
    // 呼び出し側が定期的に聞きに来る仕組みがいる。
    //
    // 記録しなかった場合 (git の外など) は届いた状態がそのまま返る。
    // Antigravity (agy) の hooks.json から呼ばれる場合は --json で空 JSON を返す
    func emit(_ value: String) {
        print(args.has("--json") ? "{}" : value)
    }
    let recorded: String
    do {
        recorded = try RecordHookEvent.touch(status: status, payload: payload)
    } catch {
        // 台帳に書けなくても、このイベントが何を意味するかは伝える。
        // 黙って落ちると、呼び出し側はタブの色を決められない
        emit(status)
        throw error
    }
    emit(recorded)
    return 0
}

func cmdSubagent(_ args: Args) throws -> Int32 {
    let action = try args.require(0, Localized.text("cli.arg.start_or_stop"))
    guard action == "start" || action == "stop" else {
        throw ProctorError(Localized.text("cli.error.invalid_subagent_action", action))
    }
    try RecordHookEvent.countSubagent(
        delta: action == "start" ? 1 : -1,
        payload: HookPayload.fromStandardInput())
    return 0
}

func cmdStats(_ args: Args) throws -> Int32 {
    try RecordSessionStats.run(HookPayload.fromStandardInput())
    return 0
}
