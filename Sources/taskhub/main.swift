import Foundation
import TaskhubKit

let usage = """
使い方: taskhub <コマンド> [オプション]

worktree ごとにエージェントを走らせて一箇所で管理する。

  new <名前>     worktree を作る
                   --base <ブランチ>  ベースブランチ (既定は設定 or origin/HEAD)
                   --ticket <キー>    チケットキーを明示する
                   --no-fetch         git fetch を省く
                   --json             結果を JSON で出す
  ls             タスク一覧
                   --all              全リポジトリを対象にする
                   --json             JSON で出す (AI・サイドバー向け)
  open <ID>      worktree のパスを出す
                   --studio           Android Studio で開く
  attach <ID>    worktree で claude を開く (続きから)
  diff <ID>      ベースからの差分を見る
                   --stat             統計だけ出す
  rm <ID>        worktree とブランチを消す
                   -f, --force        確認を飛ばして強制的に消す
  clean          マージ済みの worktree をまとめて消す (既定は一覧を出すだけ)
                   -y, --yes          実際に消す
  sidebar        iTerm2 に吸着するサイドバー (Taskhub.app) を起動する
"""

/// 値を1つ取るオプション。ここに無いものは真偽値のフラグとして扱う
let valueOptions: Set<String> = ["--base", "--ticket", "-w", "--width"]

/// --json の出力。
///
/// キーは名前順に固定する。Swift の辞書はプロセスごとに並びが変わるため、
/// 指定しないと同じ内容でも実行のたびに順序が入れ替わる。
/// この出力は AI やツールが読んで差分を取るので、揺れると扱いにくい。
func prettyJSON<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// iTerm2 の左側に吸着するサイドバー (Taskhub.app) を起動する。
///
/// 描画も iTerm2 との連携もアプリ側が持つので、ここは起動して渡すだけ。
func cmdSidebar(_ args: Args) throws -> Int32 {
    let bundle = "/Applications/Taskhub.app"
    guard FileManager.default.fileExists(atPath: bundle) else {
        throw TaskhubError(
            "Taskhub.app が見つかりません。scripts/install.sh でインストールしてください")
    }
    guard ProcessRunner.inherit(["open", "-a", bundle]) == 0 else {
        throw TaskhubError("Taskhub.app を起動できませんでした")
    }
    return 0
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

let parsed: Args
do {
    parsed = try Args(Array(argv.dropFirst()), valueOptions: valueOptions)
} catch {
    FileHandle.standardError.write(Data("taskhub: \(error)\n".utf8))
    exit(1)
}

do {
    let code: Int32
    switch command {
    case "new": code = try cmdNew(parsed)
    case "ls": code = try cmdLs(parsed)
    case "open": code = try cmdOpen(parsed)
    case "attach": code = try cmdAttach(parsed)
    case "diff": code = try cmdDiff(parsed)
    case "rm": code = try cmdRm(parsed)
    case "clean": code = try cmdClean(parsed)
    case "sidebar": code = try cmdSidebar(parsed)
    // hooks 専用。人が打つものではないのでヘルプには出さない
    case "_touch": code = try cmdTouch(parsed)
    case "_subagent": code = try cmdSubagent(parsed)
    case "_stats": code = try cmdStats(parsed)
    default:
        FileHandle.standardError.write(
            Data("taskhub: 知らないコマンドです: \(command)\n\n".utf8))
        print(usage)
        code = 2
    }
    exit(code)
} catch {
    // ファイルのコピーや作成に失敗したときも、生のスタックではなく1行で伝える。
    // --json を付けた呼び出し元は stdout だけ見ればいい
    let message = (error as? TaskhubError)?.message ?? "\(error)"
    if parsed.has("--json") {
        if let json = try? prettyJSON(["error": message]) { print(json) }
    } else {
        FileHandle.standardError.write(Data("taskhub: \(message)\n".utf8))
    }
    exit(1)
}
