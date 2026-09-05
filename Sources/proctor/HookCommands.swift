import Foundation
import Model
import Resources
import UseCaseSession
import Utility

/// hooks および statusline 連携用コマンド。判断は UseCase 層に委譲し、ここでは入出力の仲介のみを行う。

/// UserPromptSubmit フックでエージェント（Claude Code）に追加コンテキスト（命名指示）を返す JSON を生成する。
/// エスケープ処理と1行出力を担保するため compactJSON を通す。
private func namingHookJSON(_ context: String) -> String {
    (try? compactJSON(["hookSpecificOutput": [
        "hookEventName": HookPayload.userPromptSubmitEvent,
        "additionalContext": context,
    ]])) ?? "{}"
}

/// 記録後の確定状態を標準出力に返す。呼び出し側のタブ色変更等に利用する。
func cmdTouch(_ args: Args) throws -> Int32 {
    let accepted = TaskStatus.fromHooks + ["notification"]
    var status = try args.require(
        0, Localized.text("cli.arg.status", accepted.joined(separator: "|")))
    guard accepted.contains(status) else {
        throw ProctorError(Localized.text(
            "cli.error.invalid_status", accepted.joined(separator: "/"), status))
    }

    // ペイロード形式だけでは判定困難なエージェント（Codex と Claude Code 等）を識別するため、引数の明示指定を優先する
    let payload = HookPayload.fromStandardInput().naming(agent: args.value("--agent"))

    // 権限確認かアイドル通知（settled）かの判別は UseCase に委譲する。
    // アイドル通知は確認待ち状態の解除に使用される。
    if status == "notification" {
        guard let resolved = RecordHookEvent.resolveNotification(payload) else {
            if args.has("--json") { print("{}") }
            // 状態変更を伴わない通知時は何も出力しない
            return 0
        }
        status = resolved
    }
    // 呼び出し側のタブ色等と台帳表示の乖離を防ぐため、受領状態ではなく台帳に記録された確定状態（サブエージェント稼働中の done 保留など）を返す
    func emit(status value: String, hint: String?) {
        // 命名ヒントがある場合は UserPromptSubmit 向けの JSON 形式で出力する
        if let hint {
            print(namingHookJSON(hint))
            return
        }
        // UserPromptSubmit の標準出力は会話コンテキストに混入するため、命名ヒントがない場合は文字列を出力しない
        if payload.isUserPromptSubmit {
            if args.has("--json") { print("{}") }
            return
        }
        // settled は内部指示であり状態名ではないため、台帳非更新時（git 外など）にそのまま出力するのを防ぐ
        guard value != TaskStatus.settled else {
            if args.has("--json") { print("{}") }
            return
        }
        print(args.has("--json") ? "{}" : value)
    }
    let outcome: RecordHookEvent.Outcome
    do {
        outcome = try RecordHookEvent.record(status: status, payload: payload)
    } catch {
        // 台帳書き込み失敗時も、呼び出し側がタブ色等を反映できるよう受領状態を出力してからエラーを再送出する
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
    try RecordSessionStats.record(
        HookPayload.fromStandardInput().naming(agent: args.value("--agent")))
    return 0
}
