import Foundation

/// 人に知らせるに値する変化1つ。**何が起きたかだけを持ち、文面は持たない。**
///
/// 通知の題・副題・本文にどれを割り当てるかは表示の都合で、言葉も言語ごとに
/// 変わる。ここが決めるのは「どのセッションが、何になったか」まで
/// (`TaskStatus` が色を持たないのと同じ線引き)。
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

/// 前回からの変化を通知の言葉に直したもの。
///
/// 出すものと取り下げるものを一緒に返すのは、**どちらも同じ突き合わせから
/// 出てくる**ため。別々に数えさせると、片方だけ条件を直したときに
/// 「出したまま取り下げられない通知」が残る。
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
