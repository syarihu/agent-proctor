import Foundation

/// 台帳の前と後を突き合わせて、macOS の通知に出すものを決める。
///
/// **判断はここだけに置く。** 配るのはアプリ側 (Notifier) の仕事で、
/// あちらには「これを出せ・これを取り下げろ」しか渡さない。
/// 台帳も時計も読まないので、渡したものだけで答えが決まる。
public enum CollectNotices {
    /// 通知に出せる状態。ここに無い状態 (実行中・待機・確認済みなど) は
    /// 知らせない。**画面を見れば分かることを鳴らさない**ための線引きで、
    /// 出すのは「手が止まった」「終わった」「落ちた」の3つに絞る
    public static let notifiable: Set<String> = [
        TaskStatus.waiting, TaskStatus.done, TaskStatus.failed,
    ]

    /// - Parameters:
    ///   - previous: 前に見た台帳。**まだ一度も見ていなければ nil を渡す。**
    ///     起動した瞬間に、前から続いている確認待ちを一斉に鳴らさないため
    ///     (立ち上げ直しただけで、新しく起きたことは何も無い)
    ///   - current: いまの台帳
    ///   - wanted: 出してよい状態。設定で切られたものはここから外れる
    ///   - watching: いま人が見ている iTerm2 のタブ。見ていなければ nil。
    ///     **目の前で起きたことは知らせない** — 通知は「見ていないところで
    ///     起きたこと」を運ぶためのもので、見ている画面の写しではない
    public static func run(previous: [TaskRecord]?, current: [TaskRecord],
                           wanted: Set<String>, watching: String? = nil) -> NoticeChanges {
        // 前を知らないうちは何も出さない。**取り下げも出さない** —
        // 何を出したかを知らないのに取り下げると、他の何かを消しかねない
        guard let previous else { return NoticeChanges(post: [], withdraw: []) }

        // 設定で選ばれていても、通知に出せない状態は出さない。
        // ここで交わりを取らないと notifiable が「守られていない約束」になる
        let asked = wanted.intersection(notifiable)
        let before = Dictionary(previous.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let now = Dictionary(current.map { ($0.id, $0) },
                             uniquingKeysWith: { first, _ in first })

        let post: [TaskNotice] = current.compactMap { record in
            guard let status = noticeStatus(record, within: asked) else { return nil }
            // 同じ言い分で居座っているものは出さない。台帳はツール1回ごとに動くので、
            // 状態で見ないと確認待ちの間じゅう鳴り続ける。
            // **前に居なかったものは出す** (初回はもう弾いてある)
            guard noticeStatus(before[record.id], within: asked) != status else { return nil }
            if let watching, !watching.isEmpty, record.itermSession == watching { return nil }
            return TaskNotice(
                taskID: record.id,
                status: status,
                name: record.displayName,
                repoName: URL(fileURLWithPath: record.repo).lastPathComponent,
                branch: record.branch,
                // 承認を待っている間だけ中身を出す。門番の理由は
                // CollectedTask.currentRequest と同じで、承認して動き出したあとの
                // 台帳にはまだ request が残っている
                detail: status == TaskStatus.waiting ? record.request : nil)
        }

        // 片が付いたものは通知センターからも下げる。承認したあとも「⏳ 確認待ち」が
        // 積まれたままだと、通知センターが済んだ用事で埋まる。
        // 台帳から消えたもの (閉じた・片付けた) も同じ扱いにする。
        //
        // **こちらは設定ではなく notifiable で見る。** 配ったあとに設定で切られると、
        // 絞った側からは「元から出していない」ことになり、
        // 出したままの通知を下ろす者がいなくなる
        let withdraw = previous
            .filter { noticeStatus($0, within: notifiable) != nil }
            .map(\.id)
            .filter { noticeStatus(now[$0], within: notifiable) == nil }

        return NoticeChanges(post: post, withdraw: withdraw)
    }

    /// その記録について、いま通知として言うべきこと。もう用が無ければ nil。
    ///
    /// **出す側と取り下げる側で同じ問いを通す。** 別々に書くと、片方だけが
    /// 「もう人の手は要らない」と判じたときに、出したまま下ろせない通知が残る。
    /// 失敗がまさにそれで、`failed` は seenAt が付いても状態の名前が
    /// 変わらないため、状態を見比べるだけでは片が付いたことに気づけない
    /// (見たあとも通知センターに ✖ が居座る)。
    ///
    /// **見るのは attentionStatus で、displayStatus ではない。** あちらは
    /// タブを開いた時点で完了を ✔ に畳むので、素直に使うと**開いただけで
    /// 通知が下がる** —— それでは「見ただけで片付けたことにしない」という
    /// 設定 (`MarkSessionSeen.Policy.untilCleared`) が通知の側で守られない。
    private static func noticeStatus(_ record: TaskRecord?,
                                     within allowed: Set<String>) -> String? {
        guard let record,
              TaskStatus.needsPerson(status: record.status, seenAt: record.seenAt)
        else { return nil }
        let status = record.attentionStatus
        return allowed.contains(status) ? status : nil
    }
}
