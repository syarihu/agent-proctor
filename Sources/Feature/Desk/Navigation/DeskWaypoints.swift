import CoreGraphics
import Foundation

/// 事務所内の机・待機列・通路・扉の配置幾何と歩行ルート計算。
///
/// 間取りそのものは `OfficeFloorPlan` が持ち、ここはそれを引いて座標とルートを返す窓口。
/// SpriteKit シーンに依存せず純粋な座標計算として完結しているため、
/// 単体テストや独立したプレビュー・別アプリへのスピンアウトでもそのまま利用できる。
struct DeskLayout {
    let plan: OfficeFloorPlan

    var roomWidth: CGFloat { plan.size.width }
    var roomHeight: CGFloat { plan.size.height }
    var wallHeight: CGFloat { OfficeMetrics.wallHeight }

    let deskWidth: CGFloat = 184
    let deskDepth: CGFloat = 24
    let hubDeskWidth: CGFloat = 104

    init(plan: OfficeFloorPlan) {
        self.plan = plan
    }

    // MARK: - 主要ポイント

    /// 正面エントランスの扉の位置（北壁の左寄り、レート上限ボードと並ぶ位置）
    var doorPosition: CGPoint {
        // 壁に掛かるボード（中央から左へ 100pt、幅 140pt）と干渉せず、
        // 部屋の左端からも余白を保つ位置に開ける。
        //
        // さらに、南北の主通路より右には出さない。主通路はスイートの西側にあるので、
        // 扉がそれより右にあると、入ってきた人がいったん左の通路まで戻ってから
        // 右のスイートへ向かうことになり、玄関先で左右に往復して見える
        let doorX = min(plan.mainAisleX, plan.contentCenterX - 215)
        return CGPoint(x: max(64, doorX), y: roomHeight - wallHeight)
    }

    /// 正面エントランス手前の横通路の高さ (Y)
    var topHallwayY: CGFloat { plan.topHallwayY }

    /// 正面エントランス扉の真正面
    var doorFront: CGPoint {
        CGPoint(x: doorPosition.x, y: topHallwayY)
    }

    /// 正面エントランス扉の中（スポーン／消失位置）
    var doorSpawn: CGPoint {
        CGPoint(x: doorPosition.x, y: doorPosition.y + 12)
    }

    /// ツール別ホワイトボードの配置位置一覧。
    /// スイート群の中心を基準に、正面エントランス扉の右側へ順に並べる。
    func whiteboardPositions(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let centerX = plan.contentCenterX
        // 壁面中央（全高80pt）の高さに掛け金具とともに配置する
        let boardY = roomHeight - wallHeight / 2 - 2

        if count == 1 {
            return [CGPoint(x: centerX + 105, y: boardY)]
        }

        var points: [CGPoint] = []
        // 1枚目（Claude）: 中心の左側（扉 centerX - 215 と 中心の中間）
        points.append(CGPoint(x: centerX - 100, y: boardY))
        // 2枚目（Antigravity）: 中心の右側
        points.append(CGPoint(x: centerX + 100, y: boardY))
        // 3枚目以降（Codex や複数アカウント）: 右側へ順に展開
        for i in 2..<count {
            points.append(CGPoint(x: centerX + 100 + CGFloat(i - 1) * 155, y: boardY))
        }
        return points
    }

    // MARK: - 机と椅子の座標計算

    /// 島の見出し (hub) の机の位置
    func hubPoint(island: Int) -> CGPoint {
        plan.zone(island: island)?.hubPoint ?? CGPoint(x: roomWidth / 2, y: roomHeight / 2)
    }

    /// 島の中の机の位置。ハブ机を左上として、右・下へ順に並ぶ格子の中の1つ
    func seatPoint(island: Int, index: Int) -> CGPoint {
        guard let zone = plan.zone(island: island), index < zone.seatPoints.count else {
            return hubPoint(island: island)
        }
        return zone.seatPoints[index]
    }

    /// 机の後ろの椅子の位置（ディスプレイの目の前、座席の作業者の座標）
    func chairSpot(island: Int, seat: Int) -> CGPoint {
        let desk = seatPoint(island: island, index: seat)
        return CGPoint(x: desk.x, y: desk.y + 30)
    }

    /// hub の机の後ろの椅子の位置
    func hubChairSpot(island: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        return CGPoint(x: hub.x, y: hub.y + 30)
    }

    /// hub の机の前の待機列の位置
    func queuePoint(island: Int, slot: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        return CGPoint(x: hub.x,
                       y: hub.y - 38 - CGFloat(slot) * 24)
    }

    // MARK: - 歩行ルート計算

    /// 正面エントランス扉から、指定の区画の中の目的地までの折れ線。
    ///
    /// 北壁の扉 → 西の主通路 → スイートの扉 → スイートの西通路 → 区画の西通路 → 目的地。
    /// 机やプランターの上を横切らないよう、通路として空けてある帯だけを辿る
    private func routeIntoZone(target: CGPoint, island: Int, approachY: CGFloat) -> [CGPoint] {
        guard let zone = plan.zone(island: island), let suite = plan.suite(island: island) else {
            return [target]
        }

        var points: [CGPoint] = [doorFront]

        // 1. 北壁の横通路を西の主通路まで移動する
        let aisleX = plan.mainAisleX
        points.append(CGPoint(x: aisleX, y: topHallwayY))

        // 2. 主通路を南下し、スイートの扉の正面に出る
        let doorApproachY = doorApproach(suite)
        points.append(CGPoint(x: aisleX, y: doorApproachY))
        points.append(CGPoint(x: suite.doorX, y: doorApproachY))

        // 3. 扉をくぐり、区画の並びの上を通る通路へ出る
        points.append(CGPoint(x: suite.doorX, y: suite.entryLaneY))

        // 4. 目的の区画の西通路へ。
        //    行が下なら、いったんスイート西端の通路まで戻ってから南下する。
        //    区画の間の横プランターは西端だけを空けてあり、他の場所では南北に抜けられない。
        //    最初の行ならその必要は無いので、扉を入った通路のまま横へ進む
        if abs(zone.northLaneY - suite.entryLaneY) >= 1 {
            points.append(CGPoint(x: suite.aisleX, y: suite.entryLaneY))
            points.append(CGPoint(x: suite.aisleX, y: zone.northLaneY))
        }
        points.append(CGPoint(x: zone.westAisleX, y: zone.northLaneY))

        // 5. 席の背後の高さまで下り、机の後ろから着席する
        points.append(CGPoint(x: zone.westAisleX, y: approachY))
        points.append(CGPoint(x: target.x, y: approachY))
        points.append(target)

        return Self.prune(points)
    }

    /// 正面エントランス扉から指定の島のハブ机までの歩行ルート
    func hubArrivalWaypoints(island: Int) -> [CGPoint] {
        let chair = hubChairSpot(island: island)
        return routeIntoZone(target: chair, island: island, approachY: chair.y + 26)
    }

    /// 机の前や待機列から正面エントランス扉への歩行ルート
    func departureWaypoints(from start: CGPoint) -> [CGPoint] {
        guard let suite = suiteContaining(start) else {
            return Self.prune([CGPoint(x: start.x, y: start.y + 26), doorFront])
        }
        let zone = zoneContaining(start, in: suite)
        let approachY = start.y + 26

        var points: [CGPoint] = []

        // 1. 椅子から後ろ（北）へ一歩下がり、背後の通路へ出る（机やモニタを突っ切らない）
        points.append(CGPoint(x: start.x, y: approachY))

        // 2. 区画の西通路から扉の正面へ、来た道を戻る
        if let zone {
            points.append(CGPoint(x: zone.westAisleX, y: approachY))
            points.append(CGPoint(x: zone.westAisleX, y: zone.northLaneY))
            // 下の行からは、西端の通路まで戻らないと北へ抜けられない
            if abs(zone.northLaneY - suite.entryLaneY) >= 1 {
                points.append(CGPoint(x: suite.aisleX, y: zone.northLaneY))
                points.append(CGPoint(x: suite.aisleX, y: suite.entryLaneY))
            }
        } else {
            points.append(CGPoint(x: suite.aisleX, y: approachY))
            points.append(CGPoint(x: suite.aisleX, y: suite.entryLaneY))
        }
        points.append(CGPoint(x: suite.doorX, y: suite.entryLaneY))

        // 3. 扉を出て主通路を北上し、正面エントランスへ
        let doorApproachY = doorApproach(suite)
        points.append(CGPoint(x: suite.doorX, y: doorApproachY))
        points.append(CGPoint(x: plan.mainAisleX, y: doorApproachY))
        points.append(CGPoint(x: plan.mainAisleX, y: topHallwayY))
        points.append(doorFront)

        return Self.prune(points, from: start)
    }

    // MARK: - 共用ラウンジ

    /// ラウンジに用意してある席の数
    var restSpotCount: Int { plan.lounge?.seatSpots.count ?? 0 }

    /// ラウンジの席。番号が席の数を超えたら端から詰め直す
    func restSpot(index: Int) -> CGPoint? {
        guard let spots = plan.lounge?.seatSpots, !spots.isEmpty else { return nil }
        return spots[index % spots.count]
    }

    // MARK: - 補助

    /// スイートの扉の正面に立つ高さ。
    ///
    /// 一番北のスイートは上端が北壁の横通路と接しているので、単純に扉の 18pt 手前を取ると
    /// 通路より北、つまり壁の中に点が出る。そこへ寄ってから引き返す形になり、
    /// 出入りのたびに壁を往復して見える。通路より北へは出さない
    private func doorApproach(_ suite: OfficeFloorPlan.Suite) -> CGFloat {
        min(topHallwayY, suite.doorY + 18)
    }

    private func suiteContaining(_ point: CGPoint) -> OfficeFloorPlan.Suite? {
        if let hit = plan.suites.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }) {
            return hit
        }
        // 壁を出さない compact では枠の外に出ていることがあるので、一番近いスイートに寄せる
        return plan.suites.min {
            abs($0.frame.midY - point.y) < abs($1.frame.midY - point.y)
        }
    }

    private func zoneContaining(_ point: CGPoint, in suite: OfficeFloorPlan.Suite) -> OfficeFloorPlan.RepoZone? {
        if let hit = suite.zones.first(where: { $0.frame.insetBy(dx: -8, dy: -8).contains(point) }) {
            return hit
        }
        return suite.zones.min {
            hypot($0.hubPoint.x - point.x, $0.hubPoint.y - point.y)
                < hypot($1.hubPoint.x - point.x, $1.hubPoint.y - point.y)
        }
    }

    /// 折れ線から、直前の点とほぼ重なる点を落とす。
    /// そのまま `SKAction.move` に流すと 0 距離の移動が挟まって歩きがカクつくため
    private static func prune(_ points: [CGPoint], from start: CGPoint? = nil) -> [CGPoint] {
        var result: [CGPoint] = []
        var previous = start
        for point in points {
            if let previous, hypot(point.x - previous.x, point.y - previous.y) < 4 { continue }
            result.append(point)
            previous = point
        }
        if result.isEmpty, let last = points.last { result.append(last) }
        return result
    }
}
