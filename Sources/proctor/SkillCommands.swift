import Foundation
import Model
import RepositoryLedger
import Resources
import Utility

/// 同梱の手順書（スキル定義）を出力する。エージェントが最新の手順を参照できるようにする。
func cmdSkill(_ args: Args) throws -> Int32 {
    let target = args.positional.first ?? "ls"

    if target == "ls" {
        if args.has("--json") {
            print(try prettyJSON(SkillLibrary.all))
            return 0
        }
        Terminal.table(
            headers: ["SKILL", "WHAT IT COVERS"],
            rows: SkillLibrary.all.map { [$0.id, $0.summary] })
        print(Terminal.color("2", Localized.text("cli.skill.hint")))
        return 0
    }

    guard let body = SkillLibrary.body(id: target) else {
        throw ProctorError(Localized.text("cli.error.unknown_skill", target,
                                          SkillLibrary.all.map(\.id).joined(separator: ", ")))
    }
    print(body)
    return 0
}
