import Foundation
import Resources

/// 状態の語彙定義。CLI・サイドバー・メニューバーで共通して使用する。
///
/// 状態の追加時に修正箇所を局所化するため、語彙の正本をここに集約する。
/// 色の決定は各 View (CLI の ANSI / アプリの SwiftUI Palette) の責務とし、
/// ここでは状態の種類・記号・表示名の定義までを責務とする。
public enum TaskStatus {
    public static let idle = "idle"
    public static let running = "running"
    public static let waiting = "waiting"
    public static let done = "done"
    public static let failed = "failed"
    public static let missing = "missing"
    /// 閲覧済みの完了状態。台帳には保持せず、表示時に done を畳んで表現する。
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

    /// 一覧に出す状態。
    /// 完了 (done) はタブの閲覧 (openedAt) または確認クリア (seenAt) で seen に畳む。
    /// 失敗 (failed) は閲覧後も確認を要するため畳まない。
    public static func display(status: String, seenAt: Int?, openedAt: Int? = nil) -> String {
        status == done && (seenAt != nil || openedAt != nil) ? seen : status
    }

    /// 要確認と通知に出す状態。タブを開いただけでは畳まず、明示的にクリア (seenAt) されるまで維持する。
    public static func attention(status: String, seenAt: Int?) -> String {
        status == done && seenAt != nil ? seen : status
    }

    /// ユーザーによる対応が必要かどうか。
    /// 判定基準の不整合を防ぐため、attention 側の状態を基準に判定する。
    public static func needsPerson(status: String, seenAt: Int?) -> Bool {
        switch attention(status: status, seenAt: seenAt) {
        case waiting, done: return true
        case failed: return seenAt == nil
        default: return false
        }
    }

    /// 待機状態の終了を示す指示値。
    /// 権限確認のキャンセル等でフックが発火しない場合に、アイドル通知から待機解除を判定するために使用する。
    public static let settled = "settled"

    /// hooks から受け取れる状態。notification は payload 解析後の確定値が渡されるためここには含めない。
    ///
    /// failed は Claude Code の StopFailure（レートリミットや過負荷によるターン中断）用。
    /// Stop イベントが発火しない場合でも、異常終了したセッションが実行中のまま残存するのを防ぐ。
    ///
    /// idle はセッション開始・再開直後の待機状態。
    /// プロンプト送信前でも台帳にセッションを登録し、対象 worktree が未占有と誤認されるのを防ぐ。
    public static let fromHooks = [idle, running, waiting, done, failed, "clear", settled]

    public static func mark(_ status: String) -> String { marks[status] ?? "?" }
    public static func label(_ status: String) -> String {
        guard let key = labelKeys[status] else { return status }
        return Localized.text(key)
    }

    /// ユーザーの対応を要する状態の件数集計。メニューバーの要約などで使用する。
    public static func counts(_ tasks: [TaskRecord]) -> [(status: String, count: Int)] {
        let actionable = tasks.filter { needsPerson(status: $0.status, seenAt: $0.seenAt) }
        return counts(displayStatuses: actionable.map(\.attentionStatus))
    }

    /// 指定された状態一覧から件数を集計する。
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
