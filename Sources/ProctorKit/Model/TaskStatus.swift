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
    /// 終わったあと、そのタブを見たもの。**台帳には書かれない**。
    /// 見たかどうかは seenAt という別の事実で、状態遷移とは独立に決まる。
    /// 表示のときだけ done を畳んでここに寄せる (display を参照)
    public static let seen = "seen"

    public static let marks: [String: String] = [
        idle: "・",
        running: "▶",
        waiting: "⏳",
        done: "✅",
        seen: "✔",
        failed: "✖",
        missing: "⚠",
    ]

    /// 名前は言語ごとに変わるので、ここで持つのは訳文を引く鍵まで。
    /// 訳文そのものは Resources/*.lproj/Localizable.strings にある
    public static let labelKeys: [String: String] = [
        idle: "status.idle",
        running: "status.running",
        waiting: "status.waiting",
        done: "status.done",
        seen: "status.seen",
        failed: "status.failed",
        missing: "status.missing",
    ]

    /// 一覧に出したい順。数の要約もこの順に並べる
    public static let order = [waiting, running, done, seen, failed, missing, idle]

    /// 表示に使う状態。台帳の status とは別で、完了は見たかどうかで分ける。
    ///
    /// 畳むのは done だけ。失敗は見たあとも失敗のまま出す
    /// (見たからといって、片付いたわけではないため)。
    /// seenAt そのものは done と failed の両方に付く。
    public static func display(status: String, seenAt: Int?) -> String {
        status == done && seenAt != nil ? seen : status
    }

    /// 「もう待っていない」の合図。**状態ではなく指示** (`clear` と同じ立場)。
    ///
    /// 権限確認をキャンセル (Esc) すると、Claude Code はターンを止めるが
    /// **フックを1つも飛ばさない** (`PermissionDenied` は auto mode 専用で、
    /// 手で断ったときには発火しない)。何もしないと、そのタブで次に何か打つまで
    /// 確認待ちのまま居座る。
    ///
    /// 唯一届くのがアイドル通知 (`notification_type: idle_prompt` =
    /// 「応答が終わって60秒、その間何も打っていない」) で、これは
    /// **権限確認が出ている間は成立しない条件**なので、届いた時点で
    /// 「あのプロンプトはもう無い」と読める。
    public static let settled = "settled"

    /// hooks から受け取れる状態。notification はここに含めない
    /// (何を意味するかが payload 次第なので、確定した後の値がここに来る)
    ///
    /// failed は Claude Code の StopFailure (レートリミットや overloaded で
    /// ターンが落ちたとき) 用。このとき Stop は発火しないので、受け取れないと
    /// 落ちたセッションが「実行中」のまま一覧に居座る。
    ///
    /// idle はセッションが始まった (再開した) だけで、まだ何もしていないとき。
    /// これが無いと、resume したセッションは最初のプロンプトを送るまで台帳に載らず、
    /// その worktree が「誰もいない」に見え続ける
    public static let fromHooks = [idle, running, waiting, done, failed, "clear", settled]

    public static func mark(_ status: String) -> String { marks[status] ?? "?" }
    public static func label(_ status: String) -> String {
        guard let key = labelKeys[status] else { return status }
        return Localized.text(key)
    }

    /// 状態ごとの件数。メニューバーの要約などで使う。
    ///
    /// **確認済みは数えない。** ここに出したいのは「まだ手を付けていないもの」で、
    /// 見終わったものまで数えると、片付けても数字が減らない。
    /// 逆に「中に何件あるか」を出したい側は、下の displayStatuses 版を直に呼ぶ
    public static func counts(_ tasks: [TaskRecord]) -> [(status: String, count: Int)] {
        counts(displayStatuses: tasks.map(\.displayStatus).filter { $0 != seen })
    }

    /// 表示に使う状態そのものから数える。**渡されたものは全部数える。**
    ///
    /// 数えた一覧 (CollectedTask) からも呼べるように状態だけを受ける。
    /// 数え方 (件数が 0 の状態は入れない・order の順) を写し取らせないために口を分けている。
    /// どれを数えるかは呼ぶ側が決める。ここで黙って間引くと、
    /// 「状態の配列を渡したら数えてくれる」つもりの呼び出しが静かに欠ける
    public static func counts(displayStatuses: [String]) -> [(status: String, count: Int)] {
        var tally: [String: Int] = [:]
        for status in displayStatuses {
            tally[status, default: 0] += 1
        }
        return order.compactMap { key in
            guard let n = tally[key], n > 0 else { return nil }
            return (key, n)
        }
    }
}
