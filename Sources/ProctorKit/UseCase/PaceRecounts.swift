import Foundation

/// 数え直しをどれくらいの間隔で回すかを決める。
///
/// **間隔を固定にすると、1回に数秒かかるリポジトリでは git が止まらない** —
/// 10秒ごとに10秒かかる仕事を投げれば、git は常時動いていることになる。
/// そこで決めるのは秒数ではなく「**数えるのに使ってよい割合**」にした。
/// リポジトリの大きさを当てにしなくても、遅い場所では勝手に間隔が伸びる。
///
/// **判断なので UseCase に置く。** ただし平滑値という状態を持つので、
/// 他の UseCase と違って `enum` の名前空間ではなく値型にしてある。
/// 実体を持つのは呼ぶ側 (アプリの `TaskStore`) で、ここは I/O を一切しない。
/// 時計を読むのも呼ぶ側の仕事 (測るのは外の世界の出来事なので)。
public struct PaceRecounts: Sendable {
    /// これより短くはしない。今までの固定値をそのまま入れてある。
    ///
    /// 同じなのは**下限が同じ**という一点だけで、間隔が動かないわけではない。
    /// 伸び始めるのは1回が `floor / budget` (既定なら 0.5 秒) を超えてから
    public let floor: TimeInterval
    /// これより長くはしない。いくら遅くても、いつかは数え直してほしい
    public let ceiling: TimeInterval
    /// 所要時間の何倍空けるか。20 なら、git が動くのは時間の 5% に収まる
    public let budget: Double
    /// 「ここは数えるのが高い」と呼ぶ敷居 (`isExpensive`)。
    ///
    /// **`floor` や `budget` から導かない。** `interval > floor` で代用すると
    /// 敷居は 0.5 秒になり、0.6秒で返るような誰も遅いとは呼ばない
    /// リポジトリまで「高い」に入る。しかも下限や倍率を触るたびに黙って動く
    public let expensive: TimeInterval
    /// 均した所要時間。1回の揺れで間隔が跳ねないように持つ
    public private(set) var smoothed: TimeInterval

    public init(floor: TimeInterval, ceiling: TimeInterval, budget: Double,
                expensive: TimeInterval, smoothed: TimeInterval = 0) {
        self.floor = floor
        self.ceiling = ceiling
        self.budget = budget
        self.expensive = expensive
        self.smoothed = smoothed
    }

    /// セッションの一覧を数え直す間隔。下限は今までの固定値と同じ 10 秒。
    ///
    /// 敷居を 1 秒にしているのは、**人がターンの切れ目で待たされ始める境目**が
    /// そのあたりだから。エージェントが1手終えるたびに git が1秒動くなら、
    /// 数字をその場で新しくする値打ちより邪魔のほうが勝つ。
    /// それより速いうちは今までどおり、ターンの切れ目ごとに数え直す
    public static let sessions = PaceRecounts(floor: 10, ceiling: 300, budget: 20,
                                              expensive: 1)
    /// worktree を数え直す間隔。下限は今までの固定値と同じ 60 秒。
    ///
    /// こちらの敷居が緩いのは、**1回で見る量がそもそも多い**から
    /// (リポジトリごとに worktree の数だけ git が起きる)。
    /// セッションと同じ 1 秒に置くと、普通の大きさのリポジトリが軒並み
    /// 「高い」側に入ってしまう
    public static let worktrees = PaceRecounts(floor: 60, ceiling: 600, budget: 20,
                                               expensive: 3)

    /// 1回ぶんの実測を食わせる。
    ///
    /// **上がるときは即座に、下がるときはゆっくり。** 遅くなったことを均して
    /// しまうと、その間ずっと git が鳴り続ける。逆に、一度重いと分かった場所で
    /// キャッシュが温まってたまたま速く返った1回を信じて元の速さに戻すと、
    /// 次にまた掴まる。信じてよいのは「遅い」のほうだけ
    public mutating func observe(_ elapsed: TimeInterval) {
        smoothed = elapsed > smoothed ? elapsed : smoothed * 0.8 + elapsed * 0.2
    }

    /// 実測を得られなかった回に、**見積もりのほうを古びさせる**。
    ///
    /// **据え置きにすると凍る。** 呼ぶ側 (`TaskStore`) がセッションを測れるのは
    /// worktree を数えない回だけなので、セッションの `interval` が worktree の
    /// 周期を追い越すと、どの回も worktree を数える回になり**観測の機会そのものが
    /// 消える**。たまたま遅かった1回が、アプリを立ち上げ直すまで残ることになる。
    /// 減衰していれば数回で追い越しが解けて、実測を採れる回が戻ってくる。
    ///
    /// 係数が `observe` の下げ方向と同じなのは、比べられる実測が無いだけで
    /// 「前より速くなったかもしれない」の重みは変わらないため
    public mutating func decay() { smoothed *= 0.8 }

    /// 次の数え直しまで空ける時間
    public var interval: TimeInterval {
        min(ceiling, max(floor, smoothed * budget))
    }

    /// ここは数えるのが高い場所か。呼ぶ側はこれを見て、周期のほかに
    /// 数え直しを呼ぶ道 (状態が動いたとき、など) も細めるかどうかを決める。
    ///
    /// **間隔が伸びたかどうかでは判じない** (理由は `expensive`)
    public var isExpensive: Bool { smoothed > expensive }
}
