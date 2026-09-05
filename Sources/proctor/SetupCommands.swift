import Foundation
import Model
import RepositoryLedger
import Resources
import Utility

/// 繋ぎ方の手引きを渡す。
///
/// **ここは本文を出すだけで、設定ファイルには触らない。**
/// 触らない理由は SetupLibrary に書いてある (書き換えるのは読んだエージェント)。
/// 名前を選ぶのは人なので、名前が無ければ一覧を出して選べるようにする。
func cmdSetup(_ args: Args) throws -> Int32 {
    let target = args.positional.first ?? "ls"

    if target == "ls" {
        if args.has("--json") {
            print(try prettyJSON(SetupLibrary.all))
            return 0
        }
        Terminal.table(
            headers: ["AGENT", "WHAT IT COVERS"],
            rows: SetupLibrary.all.map { [$0.id, $0.summary] })
        print(Terminal.color("2", Localized.text("cli.setup.hint")))
        return 0
    }

    guard let body = SetupLibrary.body(id: target) else {
        throw ProctorError(Localized.text("cli.error.unknown_setup", target,
                                          SetupLibrary.all.map(\.id).joined(separator: ", ")))
    }
    print(body)
    return 0
}
