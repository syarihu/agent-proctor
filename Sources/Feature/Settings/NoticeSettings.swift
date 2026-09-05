import Combine
import Foundation
import Model
import UseCaseSession

/// 通知の配信条件および既読ポリシーの設定。
///
/// 外観設定（Appearance）とは責務を分離して管理する。
/// 未読解除のタイミング（seenPolicy）も、未読バッジ等の表示判定と同一のドメイン関心事であるためここに集約する。
@MainActor
public final class NoticeSettings: ObservableObject {
    @Published public var onWaiting: Bool {
        didSet { UserDefaults.standard.set(onWaiting, forKey: Self.waitingKey) }
    }
    @Published public var onDone: Bool {
        didSet { UserDefaults.standard.set(onDone, forKey: Self.doneKey) }
    }
    @Published public var onFailed: Bool {
        didSet { UserDefaults.standard.set(onFailed, forKey: Self.failedKey) }
    }
    /// 未読解除ポリシー（デフォルトはタブフォーカス時）
    @Published public var seenPolicy: MarkSessionSeen.Policy {
        didSet { UserDefaults.standard.set(seenPolicy.rawValue, forKey: Self.seenPolicyKey) }
    }

    /// 出してよい状態。`CollectNotices` に渡す形にして持つ
    public var wanted: Set<String> {
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

    public init() {
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
