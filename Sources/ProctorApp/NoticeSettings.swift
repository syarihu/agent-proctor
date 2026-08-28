import Combine
import Foundation
import ProctorKit

/// 何を知らせるか、どこまで知らせ続けるかの設定。
///
/// 見た目の設定 (`Appearance`) とは分けてある。あちらはサイドバーの描き方で、
/// こちらは**まだ手を付けていないものをどう扱うか**。同じ器に入れると、
/// 「サイドバーの設定」を直すつもりで通知を止めてしまう。
///
/// 未読をいつ降ろすか (`seenPolicy`) もここに置く。通知と要確認のストリップは
/// 同じ「まだ人の手が要るか」(`TaskStatus.needsPerson`) を見ているので、
/// 降ろす合図だけ別の器に分けると、片方の設定を探して両方が動くことになる。
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
    /// 未読をいつ降ろすか。**既定は今までどおりタブを開いた時点。**
    /// 入れた覚えのない人の手元で振る舞いが変わらないようにする
    @Published var seenPolicy: MarkSessionSeen.Policy {
        didSet { UserDefaults.standard.set(seenPolicy.rawValue, forKey: Self.seenPolicyKey) }
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
    private static let seenPolicyKey = "proctor_seen_policy"

    init() {
        // bool(forKey:) は未設定でも false を返すので、
        // 「まだ決めていない」と「切ってある」を object の有無で分ける
        onWaiting = UserDefaults.standard.object(forKey: Self.waitingKey) as? Bool ?? true
        onDone = UserDefaults.standard.object(forKey: Self.doneKey) as? Bool ?? true
        onFailed = UserDefaults.standard.object(forKey: Self.failedKey) as? Bool ?? true
        // 知らない値が入っていたら既定に落とす。選択肢の名前は後から増えうるので、
        // 古い版で書かれた値を読めなくても、そこで振る舞いが止まらないようにする
        seenPolicy = UserDefaults.standard.string(forKey: Self.seenPolicyKey)
            .flatMap(MarkSessionSeen.Policy.init(rawValue:)) ?? .onOpen
    }
}
