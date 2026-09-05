import Foundation
import Model
import RepositoryLedger
import Resources
import Utility

/// 同梱の手順書を渡す。
///
/// エージェントに読ませるためのコマンド。各エージェントの設定には
/// 「これを実行して従う」とだけ書いておけば、手引きの中身は proctor を
/// 新しくするだけで入れ替わる (写しを貼り直さなくていい)。
///
/// 繋ぎ方の手引きはここではなく `proctor setup`。作業中に読む手順と、
/// 一度きりの設定を混ぜると、どちらを読ませたいのか名前から分からなくなる。
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
