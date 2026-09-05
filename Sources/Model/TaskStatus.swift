import Foundation
import Resources

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
    /// 見たかどうかは openedAt / seenAt という別の事実で、状態遷移とは独立に決まる。
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

    /// 一覧に出す状態。台帳の status とは別で、完了は見たかどうかで分ける。
    ///
    /// 畳むのは done だけ。失敗は見たあとも失敗のまま出す
    /// (見たからといって、片付いたわけではないため)。
    /// openedAt / seenAt そのものは done と failed の両方に付く。
    ///
    /// **タブを開いた (openedAt) だけでも畳む。** 一覧に並んでいるのは
    /// 「どこで何が動いているか」で、そこに出る ✅ は「まだ中を見ていない」の印。
    /// 開いて中を見たなら役目は終わっているので、片付けを待たずに ✔ にする。
    /// やることリスト側 (要確認・通知) は下の `attention` が別に見ているので、
    /// ここで畳んでも「まだ返事をしていない」という事実までは消えない
    public static func display(status: String, seenAt: Int?, openedAt: Int? = nil) -> String {
        status == done && (seenAt != nil || openedAt != nil) ? seen : status
    }

    /// 要確認と通知に出す状態。**開いただけでは畳まない。**
    ///
    /// 降ろすのは「もう知らせなくていい」と決まったとき (seenAt) だけ。
    /// ここでも openedAt を見ると、とりあえずタブを覗いた時点でやることリストから
    /// 消えてしまい、返事をしないまま置いていったものに後から気づけない
    /// (それを避けるための `MarkSessionSeen.Policy.untilCleared`)
    public static func attention(status: String, seenAt: Int?) -> String {
        status == done && seenAt != nil ? seen : status
    }

    /// まだ人の手が要るか。確認待ちと、まだ片付けていない完了・失敗。
    ///
    /// **見るのは attention のほうで、display ではない。** 開いただけで
    /// 人の手が要らなくなるわけではないので、ここに openedAt は入らない。
    ///
    /// **seenAt の効き方が状態で違うので、線引きはここに1本だけ引く。**
    /// done は seenAt が付けば attention が seen に畳むのでそれで足りるが、
    /// failed は見たあとも failed のまま出す (見たからといって片付いたわけでは
    /// ないため)。この違いを使う側それぞれに書かせると、片方だけ直したときに
    /// **✓ を押しても消えないもの**ができる (サイドバーの新着からは消えたのに
    /// 通知センターには残る、など)。
    ///
    /// 動いていた場所が消えたもの (missing) は入れない。そこへ戻っても
    /// 見るものが無く、急かしたところで片付けられない。
    public static func needsPerson(status: String, seenAt: Int?) -> Bool {
        switch attention(status: status, seenAt: seenAt) {
        case waiting, done: return true
        case failed: return seenAt == nil
        default: return false
        }
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
    /// **確認済みは数えない。** ここに出したいのは「まだ片付けていないもの」で、
    /// 見終わったものまで数えると、片付けても数字が減らない。
    /// 逆に「中に何件あるか」を出したい側は、下の displayStatuses 版を直に呼ぶ。
    ///
    /// **数えるのは attention のほう。** ここはメニューバーに出る「残り」で、
    /// 要確認のストリップと同じものを数えていないと、上と下で数が食い違う
    /// (タブを開いた時点でメニューバーからは消えたのに要確認には残る、あるいは
    /// 失敗を片付けたのにメニューバーには残る、など)。
    /// そのため `needsPerson` を通して「まだ人の手が要るもの」だけを数える
    public static func counts(_ tasks: [TaskRecord]) -> [(status: String, count: Int)] {
        let actionable = tasks.filter { needsPerson(status: $0.status, seenAt: $0.seenAt) }
        return counts(displayStatuses: actionable.map(\.attentionStatus))
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
