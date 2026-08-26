import Combine
import Foundation
import ProctorKit

/// 何を通知するかの設定。
///
/// 見た目の設定 (`Appearance`) とは分けてある。あちらはサイドバーの描き方で、
/// こちらは**画面を見ていないときの振る舞い**。同じ器に入れると、
/// 「サイドバーの設定」を直すつもりで通知を止めてしまう。
///
/// 既定は3つとも入り。通知そのものは macOS 側で許可されるまで出ないので、
/// 入れておいても勝手に鳴り出すことはない (最初に許可を尋ねられる)。
@MainActor
final class NoticeSettings: ObservableObject {
    @Published var onWaiting: Bool {
        didSet { UserDefaults.standard.set(onWaiting, forKey: Self.waitingKey) }
    }
    @Published var onDone: Bool {
        didSet { UserDefaults.standard.set(onDone, forKey: Self.doneKey) }
    }
    @Published var onFailed: Bool {
        didSet { UserDefaults.standard.set(onFailed, forKey: Self.failedKey) }
    }

    /// 出してよい状態。`CollectNotices` に渡す形にして持つ
    var wanted: Set<String> {
        var wanted: Set<String> = []
        if onWaiting { wanted.insert(TaskStatus.waiting) }
        if onDone { wanted.insert(TaskStatus.done) }
        if onFailed { wanted.insert(TaskStatus.failed) }
        return wanted
    }

    private static let waitingKey = "proctor_notify_waiting"
    private static let doneKey = "proctor_notify_done"
    private static let failedKey = "proctor_notify_failed"

    init() {
        // bool(forKey:) は未設定でも false を返すので、
        // 「まだ決めていない」と「切ってある」を object の有無で分ける
        onWaiting = UserDefaults.standard.object(forKey: Self.waitingKey) as? Bool ?? true
        onDone = UserDefaults.standard.object(forKey: Self.doneKey) as? Bool ?? true
        onFailed = UserDefaults.standard.object(forKey: Self.failedKey) as? Bool ?? true
    }
}
