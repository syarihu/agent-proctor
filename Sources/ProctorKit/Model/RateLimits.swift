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

/// エージェント・アカウントごとのレートリミット集約情報。
public struct AgentQuotaSummary: Equatable, Identifiable {
    public var id: String { key }
    /// 集約キー ("claude", "claude:work", "agy" など)
    public var key: String
    /// エージェント種別 ("claude" または "agy")
    public var agent: String
    /// アカウント名 (例: "work", "personal", nil)
    public var account: String?
    /// 一覧に出す表示名 ("Claude Code", "Claude Code (work)", "Antigravity")
    public var agentDisplayName: String {
        let base = agent == "agy" ? "Antigravity" : "Claude Code"
        if let account, !account.isEmpty {
            return "\(base) (\(account))"
        }
        return base
    }
    public var rateLimits: AgentRateLimits

    public init(key: String? = nil, agent: String, account: String? = nil, rateLimits: AgentRateLimits) {
        let resolvedKey = key ?? (account.map { "\(agent):\($0)" } ?? agent)
        self.key = resolvedKey
        self.agent = agent
        self.account = account
        self.rateLimits = rateLimits
    }
}
