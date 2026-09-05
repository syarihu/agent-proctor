import AppState
import Combine
import FeatureSettings
import Foundation
import ItermBridge
import Model
import UseCaseNotice

/// 台帳の更新を監視し、通知対象のタスク変化を抽出して Notifier に渡すウォッチャー。
/// 読み込みタイミングの不整合を防ぐため、自前での台帳読み込みは行わず TaskStore の records 変更を購読する。
@MainActor
final class NoticeWatcher {
    private let store: TaskStore
    private let settings: NoticeSettings
    private let notifier: Notifier
    /// 前回の台帳状態。アプリ起動直後の一斉通知を防ぐため初期値は nil とする
    private var previous: [TaskRecord]?
    private var cancellable: AnyCancellable?

    init(store: TaskStore, settings: NoticeSettings, notifier: Notifier) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
        // 購読開始時の初期値で previous を初期化する
        cancellable = store.$records.sink { [weak self] records in
            self?.handle(records)
        }
    }

    private func handle(_ records: [TaskRecord]) {
        let changes = CollectNotices.collect(previous: previous, current: records,
                                             wanted: settings.wanted, watching: watching)
        previous = records
        notifier.apply(changes)
    }

    /// ユーザーが現在注視しているタブの識別子。
    /// iTerm2 が最前面でない場合は他アプリ作業中と判断し、通知を抑制しないよう nil を返す。
    private var watching: String? {
        ItermBridge.isItermFrontmost ? store.focusedSession : nil
    }
}
