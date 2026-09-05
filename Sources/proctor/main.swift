import Foundation
import Model
import Resources
import Utility

// 言語設定に応じたヘルプメッセージ
let usage = Localized.text("cli.usage")

func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    // 実行ごとの順序の揺らぎを防ぐためキーをソートする
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// 改行を含まない1行の JSON を出力する。フックの標準出力を1行単位で処理するクライアントでの誤読を防ぐ。
func compactJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    // 実行ごとの順序の揺らぎを防ぐためキーをソートする
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
    // バージョン文字列の出力（取得不可時は unknown 表記）
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
    // hooks 専用コマンド（内部利用のためヘルプ非掲載）
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
    // エラーメッセージの出力（--json 指定時は JSON 形式で標準出力に出力）
    let message = (error as? ProctorError)?.message ?? "\(error)"
    if parsed.has("--json") {
        if let json = try? prettyJSON(["error": message]) { print(json) }
    } else {
        FileHandle.standardError.write(Data("proctor: \(message)\n".utf8))
    }
    exit(1)
}
