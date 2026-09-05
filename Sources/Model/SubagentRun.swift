import Foundation
import Resources

/// 親セッション配下で実行中のサブエージェント情報。
/// 各サブエージェントの実行タスクやアクティビティを一覧表示するために使用する。
/// Claude Code 等が送信する `agent_id` をキーとして識別する。
public struct SubagentRun: Codable, Equatable, Identifiable {
    /// hooks の `agent_id`。ライフサイクル追跡の識別子
    public var id: String
    /// hooks の `agent_type` ("Explore" など)。未特定の期間は nil
    public var type: String?
    /// Task ツールの `description` ("レビュー指摘の突き合わせ" など)。
    /// `agent_type` は "general-purpose" 等の総称になりやすいため、具体的な指示内容の表示に使用する。
    public var label: String?
    /// サブエージェントが現在実行中のツール ("Grep: TaskStatus" など)
    public var activity: String?
    /// 開始時刻。経過時間の表示に使用する。
    public var startedAt: Int
    /// 最終アクティビティ時刻。
    /// タイムアウト判定 (subagentTTL) の基準。開始時刻で判定すると長時間動作中のサブエージェントが誤って破棄されるため。
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

    /// 最終アクティビティ時刻。未記録の場合は開始時刻を返す
    public var lastSeen: Int { lastSeenAt ?? startedAt }

    /// 一覧に出す見出し。名乗るものが何も無いときのための最後の受け皿を持つ
    public var displayName: String {
        if let type, !type.isEmpty { return type }
        return Localized.text("subagent.fallback_name")
    }
}
