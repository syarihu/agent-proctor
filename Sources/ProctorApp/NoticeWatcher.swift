import AppState
import Combine
import FeatureSettings
import Foundation
import ItermBridge
import Model
import UseCaseNotice

/// 台帳の変化を見張って、通知に回すものを拾う。
///
/// 判断は `CollectNotices` が持ち、配るのは `Notifier` が持つ。ここはその2つを
/// 繋ぐだけで、**前に見た台帳を覚えておく役**でもある。
///
/// 見張るのは `TaskStore` が読み直した結果 (`records`) で、台帳を自分では読まない。
/// 読む口が2つになると、どちらが先に読んだかで通知が出たり出なかったりする。
///
/// そこに載るのは iTerm2 のタブを持つセッションだけなので、**タブの無いものは
/// 知らせない**。押しても行き先が無い通知になるためで、一覧の絞り方と同じ線引き。
@MainActor
final class NoticeWatcher {
    private let store: TaskStore
    private let settings: NoticeSettings
    private let notifier: Notifier
    /// 前に見た台帳。**起動直後は nil。** 立ち上げ直しただけで
    /// 前から続いている確認待ちが一斉に鳴るのを防ぐ (判断は CollectNotices)
    private var previous: [TaskRecord]?
    private var cancellable: AnyCancellable?

    init(store: TaskStore, settings: NoticeSettings, notifier: Notifier) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
        // @Published は購読した時点の値も流すので、最初の1回で前提 (previous) が埋まる
        cancellable = store.$records.sink { [weak self] records in
            self?.handle(records)
        }
    }

    private func handle(_ records: [TaskRecord]) {
        let changes = CollectNotices.run(previous: previous, current: records,
                                         wanted: settings.wanted, watching: watching)
        previous = records
        notifier.apply(changes)
    }

    /// いま人が見ているタブ。見ていなければ nil。
    ///
    /// **iTerm2 が前面かどうかまで見る。** `focusedSession` は裏に回っても
    /// 「さっきまで見ていたタブ」を指したままなので (理由は FocusWatcher)、
    /// そこだけで判じると、別のアプリを触っている間に起きたことまで黙ってしまう。
    /// 通知がいちばん要るのはその状況になる
    private var watching: String? {
        ItermBridge.isItermFrontmost ? store.focusedSession : nil
    }
}
