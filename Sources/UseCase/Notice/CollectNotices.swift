import Foundation
import Model

/// 台帳の前と後を突き合わせて、macOS の通知に出す差分を算出する。
/// 判断のみを担い、通知の配信・取り下げの実行は呼び出し元 (Notifier) が行う。
public enum CollectNotices {
    /// 通知対象とする状態。
    /// 作業の中断や完了など、対応が必要な「waiting」「done」「failed」に限定し、不要な通知の頻発を防ぐ。
    public static let notifiable: Set<String> = [
        TaskStatus.waiting, TaskStatus.done, TaskStatus.failed,
    ]

    /// - Parameters:
    ///   - previous: 前回の台帳状態。初回起動時は nil。
    ///     nil の場合は起動直後に過去の未処理タスクが一斉に通知されるのを防ぐため、空の変更を返す。
    ///   - current: 現在の台帳状態
    ///   - wanted: 通知が有効化されている状態の集合
    ///   - watching: ユーザーが現在アクティブに閲覧している iTerm2 セッション ID。
    ///     フォアグラウンドで直接見ている画面のイベントは通知不要なため除外する。
    public static func collect(previous: [TaskRecord]?, current: [TaskRecord],
                               wanted: Set<String>, watching: String? = nil) -> NoticeChanges {
        // 前回の状態が不明な場合は、既存通知の誤った取り下げを防ぐため何も返さない。
        guard let previous else { return NoticeChanges(post: [], withdraw: []) }

        // 設定で有効化されていても、システムとして通知対象外 (notifiable) の状態は除外する。
        let asked = wanted.intersection(notifiable)
        let before = Dictionary(previous.map { ($0.id, $0) },
                                uniquingKeysWith: { first, _ in first })
        let now = Dictionary(current.map { ($0.id, $0) },
                             uniquingKeysWith: { first, _ in first })

        let post: [TaskNotice] = current.compactMap { record in
            guard let status = noticeStatus(record, within: asked) else { return nil }
            // 台帳はツール実行ごとに更新されるため、状態に変化がないタスクの再通知を抑制する。
            // 前回存在しなかった新規タスクは通知対象とする。
            guard noticeStatus(before[record.id], within: asked) != status else { return nil }
            if let watching, !watching.isEmpty, record.itermSession == watching { return nil }
            return TaskNotice(
                taskID: record.id,
                status: status,
                name: record.displayName,
                repoName: URL(fileURLWithPath: record.repo).lastPathComponent,
                branch: record.branch,
                // 承認実行後も台帳に直前の request 文字列が残る場合があるため、承認待ちの間のみ詳細本文を設定する。
                detail: status == TaskStatus.waiting ? record.request : nil)
        }

        // 通知対象から外れたタスクや台帳から削除されたタスクの通知を取り下げる。
        // 設定変更で wanted から外れた場合でも正しく通知を取り下げられるよう、
        // 判定には wanted ではなく notifiable を用いる。
        let withdraw = previous
            .filter { noticeStatus($0, within: notifiable) != nil }
            .map(\.id)
            .filter { noticeStatus(now[$0], within: notifiable) == nil }

        return NoticeChanges(post: post, withdraw: withdraw)
    }

    /// レコードから通知対象のステータスを抽出する。対象外または対応不要なら nil。
    /// 配信判定と取り下げ判定で同一のロジックを通すことで、通知の取り下げ漏れを防ぐ。
    /// displayStatus ではなく attentionStatus を参照するのは、セッション表示を開いただけで
    /// untilCleared ポリシーの通知が誤って消去されるのを防ぐため。
    private static func noticeStatus(_ record: TaskRecord?,
                                     within allowed: Set<String>) -> String? {
        guard let record,
              TaskStatus.needsPerson(status: record.status, seenAt: record.seenAt)
        else { return nil }
        let status = record.attentionStatus
        return allowed.contains(status) ? status : nil
    }
}
