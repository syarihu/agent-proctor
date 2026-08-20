import Foundation

/// 親セッションの下で走っているサブエージェント1体。
///
/// 数 (`TaskRecord.subagents`) では「2体いる」までしか言えず、何をさせているのかは
/// 結局タブを見に行くしかなかった。ここに1体ずつ持たせることで、
/// 誰が何をしているかまで一覧の中で分かるようにする。
///
/// 個体を見分ける鍵は Claude Code が hooks に載せてくる `agent_id`。
/// これが無いエージェント (Antigravity など) は今まで通り数だけを持つので、
/// この配列は空のままになる。
public struct SubagentRun: Codable, Equatable, Identifiable {
    /// hooks の `agent_id`。始まりと終わりを結ぶ鍵になる
    public var id: String
    /// hooks の `agent_type` ("Explore" など)。分かるまでは nil
    public var type: String?
    /// Task ツールの `description` ("レビュー指摘の突き合わせ" など)。
    ///
    /// **何をさせているか**はこれでしか分からない。`agent_type` は
    /// "general-purpose" のように器の名前でしかないことが多い
    public var label: String?
    /// この子がいま触っているツール ("Grep: TaskStatus" など)
    public var activity: String?
    /// 生まれた時刻。**経過の表示はこちらを使う**
    public var startedAt: Int
    /// 最後にこの子の声を聞いた時刻。
    ///
    /// **打ち切り (subagentTTL) の起点はこちら。** 生まれた時刻で切ると、
    /// 何時間も走り続けている子が「今まさに喋っているのに」時間切れで消される。
    /// 消えた拍子に親の預かった終わりが確定してしまい、走っている最中に
    /// 完了の印が付く。無いときは生まれた時刻で代用する
    public var lastSeenAt: Int?

    public init(id: String, type: String? = nil, label: String? = nil,
                activity: String? = nil, startedAt: Int, lastSeenAt: Int? = nil) {
        self.id = id
        self.type = type
        self.label = label
        self.activity = activity
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
    }

    /// 最後に声を聞いた時刻。生まれてから一度も聞いていなければ生まれた時刻
    public var lastSeen: Int { lastSeenAt ?? startedAt }

    /// 一覧に出す見出し。名乗るものが何も無いときのための最後の受け皿を持つ
    public var displayName: String {
        if let type, !type.isEmpty { return type }
        return "サブエージェント"
    }
}
