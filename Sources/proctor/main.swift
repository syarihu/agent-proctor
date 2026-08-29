import Foundation
import ProctorKit

// ヘルプもシステムの言語で出す。訳文は ProctorKit の Localizable.strings
let usage = Localized.text("cli.usage")

func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    // キーは名前順に固定する。Swift の辞書はプロセスごとに並びが変わるため、
    // 指定しないと同じ内容でも実行のたびに順序が入れ替わる。
    // この出力は AI やツールが読んで差分を取るので、揺れると扱いにくい
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// 改行を含まない1行の JSON。**フックの返事はこちらで書く。**
///
/// 人が読む出力 (`--json`) は `prettyJSON` の整形のままでよいが、**フックの stdout を
/// 読む側は行単位で拾うことがある**。`{` で始まる最初の1行だけを見て JSON として
/// 解釈する実装は珍しくなく、そこへ整形済みの JSON を渡すと `{` だけを掴まれて
/// 「JSON のようだが壊れている」と言われる。1行に畳んでおけば、行で切る相手にも丸ごと渡る。
///
/// 整形のほうが読みやすいのは確かだが、これを読むのは人ではなくエージェントの
/// 実行環境なので、読みやすさより確実に届くことを取る
func compactJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    // 並びを固定する理由は prettyJSON と同じ (Swift の辞書は実行のたびに並びが変わる)
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

let argv = Array(CommandLine.arguments.dropFirst())
guard let command = argv.first else {
    print(usage)
    exit(2)
}
if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}
if command == "-v" || command == "--version" || command == "version" {
    // "proctor 0.1.0" の形。読むのが機械のこともあるので、版そのものは訳さない。
    // .app の外から走らせていると版が分からないので、そのときはそう言う
    // (それらしい数字を出すと、どのビルドの話か分からなくなる)
    print("proctor \(AppVersion.current ?? Localized.text("common.version.unknown"))")
    exit(0)
}

let parsed = Args(Array(argv.dropFirst()))

do {
    let code: Int32
    switch command {
    case "ls": code = try cmdLs(parsed)
    case "worktree": code = try cmdWorktree(parsed)
    case "skill": code = try cmdSkill(parsed)
    case "setup": code = try cmdSetup(parsed)
    case "attach": code = try cmdAttach(parsed)
    case "rm": code = try cmdRm(parsed)
    case "title": code = try cmdTitle(parsed)
    case "sidebar": code = try cmdSidebar(parsed)
    // hooks 専用。人が打つものではないのでヘルプには出さない
    case "_touch": code = try cmdTouch(parsed)
    case "_subagent": code = try cmdSubagent(parsed)
    case "_stats": code = try cmdStats(parsed)
    default:
        FileHandle.standardError.write(
            Data("proctor: \(Localized.text("cli.unknown_command", command))\n\n".utf8))
        print(usage)
        code = 2
    }
    exit(code)
} catch {
    // 生のスタックではなく1行で伝える。
    // --json を付けた呼び出し元は stdout だけ見ればいい
    let message = (error as? ProctorError)?.message ?? "\(error)"
    if parsed.has("--json") {
        if let json = try? prettyJSON(["error": message]) { print(json) }
    } else {
        FileHandle.standardError.write(Data("proctor: \(message)\n".utf8))
    }
    exit(1)
}
