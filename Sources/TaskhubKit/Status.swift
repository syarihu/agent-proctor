import Foundation

/// 状態の見せ方はここが正本。CLI の表もサイドバーもメニューバーもこれを使う。
///
/// 語彙は状態を流し込む hooks 側と揃えている
/// (▶ 実行中 / ⏳ 確認待ち / ✅ 完了)。
/// 状態を1つ足すときにここだけ直せば済むよう、表示側には定義を持たせない。
public enum Status {
    public static let marks: [String: String] = [
        "idle": "・",
        "running": "▶",
        "waiting": "⏳",
        "done": "✅",
        "failed": "✖",
        "missing": "⚠",
    ]

    public static let labels: [String: String] = [
        "idle": "待機",
        "running": "実行中",
        "waiting": "確認待ち",
        "done": "完了",
        "failed": "失敗",
        "missing": "消失",
    ]

    /// CLI の表で使う ANSI の色番号
    public static let colors: [String: String] = [
        "idle": "2",
        "running": "36",
        "waiting": "33",
        "done": "32",
        "failed": "31",
        "missing": "31",
    ]

    /// 一覧に出したい順。数の要約もこの順に並べる
    public static let order = ["waiting", "running", "done", "failed", "missing", "idle"]

    public static func mark(_ status: String) -> String { marks[status] ?? "?" }

    /// 状態を (表示用のラベル, ANSI の色) にする。表示側はこれを使う。
    public static func style(_ status: String) -> (label: String, color: String) {
        ("\(mark(status)) \(labels[status] ?? status)", colors[status] ?? "0")
    }

    /// 状態ごとの件数。メニューバーの要約などで使う。
    ///
    /// 件数が 0 の状態は入れない。何も動いていなければ空になる。
    /// 呼び出し側が並べ替えずに済むよう order の順で返す。
    public static func counts(_ tasks: [TaskRecord]) -> [(status: String, count: Int)] {
        var tally: [String: Int] = [:]
        for task in tasks { tally[task.status, default: 0] += 1 }
        return order.compactMap { key in
            guard let n = tally[key], n > 0 else { return nil }
            return (key, n)
        }
    }
}
