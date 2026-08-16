import Foundation
import TaskhubKit

/// hooks と statusline から呼ばれるコマンド。人が打つものではない。
/// 判断は UseCase 側が持ち、ここは受け渡しだけにする。

/// 記録した状態を stdout に返す。呼び出し側が「結局どうなったか」を使えるようにする
/// (タブの色を変えるなど)。判断をシェル側に写すと、片方だけ直したときに食い違う。
func cmdTouch(_ args: Args) throws -> Int32 {
    let accepted = TaskStatus.fromHooks + ["notification"]
    var status = try args.require(0, "状態 (\(accepted.joined(separator: "|")))")
    guard accepted.contains(status) else {
        throw TaskhubError(
            "状態は \(accepted.joined(separator: "/")) のいずれかです: \(status)")
    }

    let payload = HookPayload.fromStandardInput()

    // notification は権限確認でもアイドル通知でも飛んでくる。
    // どちらなのかの判断は UseCase が持つ
    if status == "notification" {
        guard let resolved = RecordHookEvent.resolveNotification(payload) else {
            return 0  // アイドル通知。何も出さないことで「変えない」を伝える
        }
        status = resolved
    }
    // 台帳を触る前に返す。git の外での実行など、記録しない場合でも
    // 「このイベントは確認待ちを意味する」ことは呼び出し側に伝わってほしい
    print(status)

    try RecordHookEvent.touch(status: status, payload: payload)
    return 0
}

func cmdSubagent(_ args: Args) throws -> Int32 {
    let action = try args.require(0, "start か stop")
    guard action == "start" || action == "stop" else {
        throw TaskhubError("start か stop を指定してください: \(action)")
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
