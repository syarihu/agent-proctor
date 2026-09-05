import Foundation

/// リポジトリの計測コストに応じた適応型の再集計間隔を管理する。
/// 固定間隔では負荷の高いリポジトリで git プロセスが常時稼働してしまうため、
/// 経過時間に応じた budget（所要時間の何倍間隔を空けるか）によって間隔を動的に算出する。
/// 状態（平滑化された所要時間）を保持するため構造体として定義されている。
public struct PaceRecounts: Sendable {
    /// 再集計間隔の下限値（秒）。
    public let floor: TimeInterval
    /// 再集計間隔の上限値（秒）。
    public let ceiling: TimeInterval
    /// 実行時間に対するインターバルの倍率。20 の場合、処理時間が全体の 5% 以下に収まるよう調整される。
    public let budget: Double
    /// 高負荷リポジトリと判定する所要時間の閾値（秒）。
    /// 下限値や倍率の変更から独立させるため個別の定数として設定する。
    public let expensive: TimeInterval
    /// 指数平滑化された処理所要時間。突発的なスパイクによる急激な間隔変動を抑える。
    public private(set) var smoothed: TimeInterval

    public init(floor: TimeInterval, ceiling: TimeInterval, budget: Double,
                expensive: TimeInterval, smoothed: TimeInterval = 0) {
        self.floor = floor
        self.ceiling = ceiling
        self.budget = budget
        self.expensive = expensive
        self.smoothed = smoothed
    }

    /// セッション一覧の再集計間隔設定。下限 10 秒。
    /// 1 秒以上の処理負荷が発生する場合は、ユーザー操作の応答性を損なわないよう頻度を落とす。
    public static let sessions = PaceRecounts(floor: 10, ceiling: 300, budget: 20,
                                              expensive: 1)
    /// worktree 一覧の再集計間隔設定。下限 60 秒。
    /// worktree 数に応じた複数回の git 呼び出しを伴いベース負荷が高いため、閾値を 3 秒に設定する。
    public static let worktrees = PaceRecounts(floor: 60, ceiling: 600, budget: 20,
                                               expensive: 3)

    /// 実測時間を反映する。
    /// 負荷増大時は即座に応答して間隔を延ばし、負荷低下時はキャッシュ効果による一時的な高速化の
    /// 影響を抑えるため指数平滑（0.8:0.2）で緩やかに回復させる。
    public mutating func observe(_ elapsed: TimeInterval) {
        smoothed = elapsed > smoothed ? elapsed : smoothed * 0.8 + elapsed * 0.2
    }

    /// 計測がスキップされた回に見積もり時間を減衰させる。
    /// セッションの計測間隔が worktree の計測周期を上回ると観測機会が失われて間隔が固定化する
    /// 恐れがあるため、観測が行われなかった場合も一定割合で減衰させて再観測の機会を確保する。
    public mutating func decay() { smoothed *= 0.8 }

    /// 次の再集計までのインターバル（秒）。
    public var interval: TimeInterval {
        min(ceiling, max(floor, smoothed * budget))
    }

    /// 高負荷状態かどうか。呼び出し元はこれに応じてイベント駆動の更新を間引く。
    public var isExpensive: Bool { smoothed > expensive }
}
