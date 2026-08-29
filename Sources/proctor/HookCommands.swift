import Foundation
import ProctorKit

/// hooks と statusline から呼ばれるコマンド。人が打つものではない。
/// 判断は UseCase 側が持ち、ここは受け渡しだけにする。

/// UserPromptSubmit のフックが「会話に一言足す」ときの返し方。
///
/// **View の仕事なので Kit には持たせない。** これは Claude Code という
/// 特定の相手との約束事の形であって、proctor が何を伝えたいかの話ではない
/// (伝えたい中身を決めるのは `NameSession.namingHint`)。
///
/// 組み立てに `compactJSON` を通す理由は2つ。文字列の逃がし方を手で書かないため
/// (本文には引用符も改行も入りうる) と、改行を入れないため (理由は `compactJSON`)。
///
/// イベント名は綴らずに `HookPayload.userPromptSubmitEvent` から引く (理由はそちら)
private func namingHookJSON(_ context: String) -> String {
    (try? compactJSON(["hookSpecificOutput": [
        "hookEventName": HookPayload.userPromptSubmitEvent,
        "additionalContext": context,
    ]])) ?? "{}"
}

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

    // hooks を書く側が `--agent=codex` と名乗れる。payload の形だけでは
    // Codex と Claude Code の区別が付かないため、名乗りがあればそれを優先する
    let payload = HookPayload.fromStandardInput().naming(agent: args.value("--agent"))

    // notification は権限確認でもアイドル通知でも飛んでくる。
    // どちらなのかの判断は UseCase が持つ。
    //
    // **アイドル通知も台帳まで通す。** あれは「応答が終わって暇になった」の合図で、
    // 確認待ちで居座っている行を降ろすのに使う (理由は TaskStatus.settled)。
    // 降ろしたのかどうかは、下と同じく**記録した状態**として返る
    if status == "notification" {
        guard let resolved = RecordHookEvent.resolveNotification(payload) else {
            if args.has("--json") { print("{}") }
            // 状態と関係のない通知 (認証できた等)。
            // 何も出さないことで、呼び出し側に「変えない」を伝える
            return 0
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
    func emit(status value: String, hint: String?) {
        // 囁きがあるのは UserPromptSubmit のときだけ (`NameSession.namingHint`)。
        // **`--json` でも囁きを優先する** ——「状態の文字列を出さない」という
        // `--json` の約束は、JSON を出すことで守られている
        if let hint {
            print(namingHookJSON(hint))
            return
        }
        // **UserPromptSubmit の素の stdout は、そのまま会話の文脈に注ぎ込まれる。**
        // ここで状態を返すと、毎ターン "running" の一語が会話に混ざる。
        // このイベントで喋ってよいのは上の囁きだけなので、それが無いなら黙る
        if payload.isUserPromptSubmit {
            if args.has("--json") { print("{}") }
            return
        }
        // **指示はそのまま返さない。** settled は「もう待っていない」の合図で、
        // 状態ではない。台帳に映せなかったとき (git の外・まだ載っていない・
        // 書けなかった) にそのまま返すと、タブの色を決める側に
        // 実在しない状態が渡る。映せたときは実際に書いた状態が返る
        guard value != TaskStatus.settled else {
            if args.has("--json") { print("{}") }
            return
        }
        print(args.has("--json") ? "{}" : value)
    }
    let outcome: RecordHookEvent.Outcome
    do {
        outcome = try RecordHookEvent.touch(status: status, payload: payload)
    } catch {
        // 台帳に書けなくても、このイベントが何を意味するかは伝える。
        // 黙って落ちると、呼び出し側はタブの色を決められない。
        // 囁きは台帳を見ないと決められないので、書けなかった回は出さない
        emit(status: status, hint: nil)
        throw error
    }
    emit(status: outcome.status,
         hint: NameSession.namingHint(payload: payload, unnamed: outcome.unnamed))
    return 0
}

func cmdSubagent(_ args: Args) throws -> Int32 {
    let action = try args.require(0, Localized.text("cli.arg.start_or_stop"))
    guard action == "start" || action == "stop" else {
        throw ProctorError(Localized.text("cli.error.invalid_subagent_action", action))
    }
    try RecordHookEvent.countSubagent(
        delta: action == "start" ? 1 : -1,
        payload: HookPayload.fromStandardInput().naming(agent: args.value("--agent")))
    return 0
}

func cmdStats(_ args: Args) throws -> Int32 {
    try RecordSessionStats.run(
        HookPayload.fromStandardInput().naming(agent: args.value("--agent")))
    return 0
}
