import Foundation

/// 状態の語彙。ここが正本で、CLI もサイドバーもメニューバーもこれを使う。
///
/// 語彙は状態を流し込む hooks 側と揃えている
/// (▶ 実行中 / ⏳ 確認待ち / ✅ 完了)。
/// 状態を1つ足すときにここだけ直せば済むよう、表示側には定義を持たせない。
///
/// ただし**色は持たない**。端末の ANSI とアプリの SwiftUI では表現が違うので、
/// それぞれの View 側で決める。ここが知っているのは「何という状態があり、
/// どんな記号と名前で呼ぶか」まで。
public enum TaskStatus {
    public static let idle = "idle"
    public static let running = "running"
    public static let waiting = "waiting"
    public static let done = "done"
    public static let failed = "failed"
    public static let missing = "missing"

    public static let marks: [String: String] = [
        idle: "・",
        running: "▶",
        waiting: "⏳",
        done: "✅",
        failed: "✖",
        missing: "⚠",
    ]

    public static let labels: [String: String] = [
        idle: "待機",
        running: "実行中",
        waiting: "確認待ち",
        done: "完了",
        failed: "失敗",
        missing: "消失",
    ]

    /// 一覧に出したい順。数の要約もこの順に並べる
    public static let order = [waiting, running, done, failed, missing, idle]

    /// hooks から受け取れる状態。notification はここに含めない
    /// (何を意味するかが payload 次第なので、確定した後の値がここに来る)
    public static let fromHooks = [running, waiting, done, "clear"]

    public static func mark(_ status: String) -> String { marks[status] ?? "?" }
    public static func label(_ status: String) -> String { labels[status] ?? status }

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
