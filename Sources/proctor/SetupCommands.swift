import Foundation
import Model
import RepositoryLedger
import Resources
import Utility

/// エージェント設定の手引きを出力する。実際の設定ファイル更新は読み手のエージェントに委ねるため本文の表示のみ行う。
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
