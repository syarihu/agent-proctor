import Foundation

/// 人に知らせるに値する変化1件。イベント情報のみを保持し、通知文面は持たない。
///
/// 表示文言は言語設定等に応じた表示層の責務であり、
/// ここでは対象セッションと変更後状態の特定までを責務とする。
public struct TaskNotice: Equatable {
    /// 押されたときに開くセッション。台帳の id
    public let taskID: String
    /// 変わった先の状態。`TaskStatus` の語彙
    public let status: String
    /// 一覧と同じ見出し。どの作業の話かはこれで分かる
    public let name: String
    /// リポジトリ名 (パスではなく名前)。同じ名前の作業が並ぶときの手がかり
    public let repoName: String
    public let branch: String
    /// 何を待っているか (確認待ちのときの request)。それ以外では nil。
    /// 「もうやったこと」(activity) は入れない — 知らせたいのはこれからのこと
    public let detail: String?

    public init(taskID: String, status: String, name: String,
                repoName: String, branch: String, detail: String?) {
        self.taskID = taskID
        self.status = status
        self.name = name
        self.repoName = repoName
        self.branch = branch
        self.detail = detail
    }
}

/// 前回からの変化を通知用にまとめたもの。
///
/// 発行対象と取り下げ対象を同時に返すのは、同一の突合処理から導出するため。
/// 算出を分けると条件不一致により取り下げ漏れが発生するのを防ぐ。
public struct NoticeChanges: Equatable {
    /// これから出すもの
    public let post: [TaskNotice]
    /// もう出しておく意味の無くなったセッションの id。
    /// 確認待ちを承認した・完了を見た、など片が付いたもの
    public let withdraw: [String]

    public init(post: [TaskNotice], withdraw: [String]) {
        self.post = post
        self.withdraw = withdraw
    }

    public var isEmpty: Bool { post.isEmpty && withdraw.isEmpty }
}
