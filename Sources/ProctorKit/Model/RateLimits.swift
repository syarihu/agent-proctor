import Foundation

/// レートリミットの1枠（5時間枠、7日間枠など）。
public struct RateLimitWindow: Codable, Equatable {
    /// 使用率 (%)。0〜100 の整数
    public var usedPercent: Int
    /// リセット予定時刻（Unix epoch 秒）。過ぎているか不明なら nil
    public var resetsAt: Int?

    public init(usedPercent: Int, resetsAt: Int? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// エージェントのレートリミット情報。
///
/// Claude Code や Antigravity の statusline から送られてくる
/// 5時間枠 (five_hour) と 7日間枠 (seven_day) の使用状況。
public struct AgentRateLimits: Codable, Equatable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?

    public init(fiveHour: RateLimitWindow? = nil, sevenDay: RateLimitWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public var isEmpty: Bool {
        fiveHour == nil && sevenDay == nil
    }
}

/// エージェントごとのレートリミット集約情報。
public struct AgentQuotaSummary: Equatable, Identifiable {
    public var id: String { agent }
    /// エージェント種別 ("claude" または "agy")
    public var agent: String
    /// 一覧に出す表示名 ("Claude Code" または "Antigravity")
    public var agentDisplayName: String {
        agent == "agy" ? "Antigravity" : "Claude Code"
    }
    public var rateLimits: AgentRateLimits

    public init(agent: String, rateLimits: AgentRateLimits) {
        self.agent = agent
        self.rateLimits = rateLimits
    }
}
