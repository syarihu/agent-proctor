import CoreGraphics
import Foundation

/// 事務所内の机・待機列・通路・扉の配置幾何と歩行ルート計算。
///
/// SpriteKit シーンに依存せず純粋な座標計算として完結しているため、
/// 単体テストや独立したプレビュー・別アプリへのスピンアウトでもそのまま利用できる。
struct DeskLayout {
    let roomWidth: CGFloat
    let roomHeight: CGFloat
    let wallHeight: CGFloat = 32
    let topMargin: CGFloat = 125
    let bottomMargin: CGFloat = 80
    let islandSpacing: CGFloat = 160
    let islandHeight: CGFloat
    let columns: Int = 1
    let seatColumns: Int
    let columnPitch: CGFloat
    let deskWidth: CGFloat = 184
    let deskDepth: CGFloat = 32
    let hubDeskWidth: CGFloat = 104
    let hubRowSpacing: CGFloat = 58
    let rowSpacing: CGFloat = 78

    // MARK: - 主要ポイント

    /// 正面エントランスの扉の位置（奥壁の左上）
    var doorPosition: CGPoint {
        CGPoint(x: 54, y: roomHeight - wallHeight)
    }

    /// 正面エントランス手前の横通路の高さ (Y)
    var topHallwayY: CGFloat {
        roomHeight - wallHeight - 16
    }

    /// 正面エントランス扉の真正面
    var doorFront: CGPoint {
        CGPoint(x: doorPosition.x, y: topHallwayY)
    }

    /// 正面エントランス扉の中（スポーン／消失位置）
    var doorSpawn: CGPoint {
        CGPoint(x: doorPosition.x, y: doorPosition.y + 6)
    }

    // MARK: - 机と椅子の座標計算

    /// 島の見出し (hub) の机の位置
    func hubPoint(island: Int) -> CGPoint {
        let column = CGFloat(island % columns)
        let row = CGFloat(island / columns)
        let spread = islandSpacing * CGFloat(columns - 1)
        return CGPoint(x: roomWidth / 2 - spread / 2 + islandSpacing * column,
                       y: roomHeight - topMargin - islandHeight * row)
    }

    /// 島の中の机の位置。上の段から、左から順に詰めていく
    func seatPoint(island: Int, index: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        let spread = columnPitch * CGFloat(seatColumns - 1)
        let row = index / seatColumns
        return CGPoint(x: hub.x - spread / 2 + columnPitch * CGFloat(index % seatColumns),
                       y: hub.y - hubRowSpacing - rowSpacing * CGFloat(row))
    }

    /// 机の後ろの椅子の位置（ディスプレイの目の前、座席の作業者の座標）
    func chairSpot(island: Int, seat: Int) -> CGPoint {
        let desk = seatPoint(island: island, index: seat)
        return CGPoint(x: desk.x, y: desk.y + 30)
    }

    /// hub の机の前の待機列の位置
    func queuePoint(island: Int, slot: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        return CGPoint(x: hub.x,
                       y: hub.y - 38 - CGFloat(slot) * 24)
    }

    // MARK: - 歩行ルート計算

    /// 正面エントランス扉から指定の机の前までの歩行ルート
    func arrivalWaypoints(to target: CGPoint, island: Int, seatIndex: Int) -> [CGPoint] {
        let hub = hubPoint(island: island)
        let spread = columnPitch * CGFloat(seatColumns - 1)
        let col0X = hub.x - spread / 2
        let column = seatIndex % seatColumns

        let aisleX: CGFloat
        if seatColumns > 1 {
            let gapIndex = max(0, min(seatColumns - 2, column == 0 ? 0 : column - 1))
            let leftColX = col0X + columnPitch * CGFloat(gapIndex)
            let rightColX = leftColX + columnPitch
            aisleX = (leftColX + rightColX) / 2
        } else {
            aisleX = max(doorPosition.x + 30, min(col0X - (deskWidth / 2 + 14), target.x - 16))
        }

        var points: [CGPoint] = []

        // 1. 扉の正面（上部横通路）へ出る
        points.append(doorFront)

        // 2. 上部横通路を通って、机の左側の南北主通路 (aisleX) の入口へ進む
        if abs(doorFront.x - aisleX) >= 4 {
            points.append(CGPoint(x: aisleX, y: topHallwayY))
        }

        // 3. 南北主通路を自分の席の段まで進む
        if abs(topHallwayY - target.y) >= 4 {
            points.append(CGPoint(x: aisleX, y: target.y))
        }

        // 4. 自分の席（椅子の位置）に入る
        if abs(aisleX - target.x) >= 4 {
            points.append(target)
        }

        return points
    }

    /// 机の前や待機列から正面エントランス扉への歩行ルート
    func departureWaypoints(from start: CGPoint) -> [CGPoint] {
        let hubX = roomWidth / 2
        let col0X = hubX - columnPitch * CGFloat(seatColumns - 1) / 2
        let aisleX = max(doorPosition.x + 30, min(col0X - (deskWidth / 2 + 14), start.x - 16))

        var points: [CGPoint] = []

        // 1. 南北主通路（左側の通路）へ横移動
        if abs(start.x - aisleX) >= 4 {
            points.append(CGPoint(x: aisleX, y: start.y))
        }

        // 2. 南北主通路を北上して上部横通路へ
        if abs(start.y - topHallwayY) >= 4 {
            points.append(CGPoint(x: aisleX, y: topHallwayY))
        }

        // 3. 上部横通路を通って扉の正面へ進む
        if abs(aisleX - doorFront.x) >= 4 {
            points.append(doorFront)
        }

        return points
    }

    /// 待機列へ向かう／待機列から席へ戻るための歩行ルート
    func queueWaypoints(from start: CGPoint, to target: CGPoint, island: Int, seatIndex: Int) -> [CGPoint] {
        guard hypot(start.x - target.x, start.y - target.y) >= 2 else { return [] }

        // すでに同じ高さにいるなら直線で歩ける
        if abs(start.y - target.y) < 4 {
            return [target]
        }

        let hub = hubPoint(island: island)

        // 待機列内での前後移動
        if abs(start.x - target.x) < 4 && start.y >= hub.y - 120 && target.y >= hub.y - 120 {
            return [target]
        }

        let row = seatIndex / seatColumns

        // 最上段（Row 0）の席とハブ机の間には机が存在しないため直線
        if row == 0 && seatColumns == 1 {
            return [target]
        }

        let isGoingToQueue = target.y > start.y

        if seatColumns > 1 {
            let centerAisleX = hub.x
            var points: [CGPoint] = []
            if isGoingToQueue {
                if abs(start.x - centerAisleX) >= 4 {
                    points.append(CGPoint(x: centerAisleX, y: start.y))
                }
                points.append(target)
            } else {
                if abs(centerAisleX - target.x) >= 4 {
                    points.append(CGPoint(x: centerAisleX, y: target.y))
                }
                points.append(target)
            }
            return points
        } else {
            let aisleX = hub.x - (deskWidth / 2 + 14)
            var points: [CGPoint] = []
            if abs(start.x - aisleX) >= 4 {
                points.append(CGPoint(x: aisleX, y: start.y))
            }
            points.append(CGPoint(x: aisleX, y: target.y))
            if abs(aisleX - target.x) >= 4 {
                points.append(target)
            }
            return points
        }
    }
}
