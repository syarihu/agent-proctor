import CoreGraphics
import Foundation

/// 事務所内の机・待機列・通路・扉の配置幾何と歩行ルート計算。
///
/// SpriteKit シーンに依存せず純粋な座標計算として完結しているため、
/// 単体テストや独立したプレビュー・別アプリへのスピンアウトでもそのまま利用できる。
struct DeskLayout {
    let roomWidth: CGFloat
    let roomHeight: CGFloat
    let wallHeight: CGFloat = 80
    // 壁（80pt）と上部通路（20pt）、および人間の思考雲（高さ約34pt＋頭上余白）が
    // 互いに干渉せず、人物の背後にゆったりとした北壁空間を確保するために 210pt を確保する
    let topMargin: CGFloat = 210
    let bottomMargin: CGFloat = 60
    let islandSpacing: CGFloat
    let islandHeight: CGFloat
    let columns: Int = 1
    let seatColumns: Int
    let columnPitch: CGFloat
    let deskWidth: CGFloat = 184
    let deskDepth: CGFloat = 24
    let hubDeskWidth: CGFloat = 104
    let hubRowSpacing: CGFloat = 145
    let rowSpacing: CGFloat = 185

    // MARK: - 主要ポイント

    /// 正面エントランスの扉の位置（奥壁の左寄り、ホワイトボードと並ぶ位置）
    var doorPosition: CGPoint {
        let hubX = roomWidth / 2
        // 人間の左側に配置するホワイトボード（幅140、hubX - 100）と干渉せず、
        // 部屋の左端からも適度な余白（最小64pt）を保つために hubX - 215 に配置する
        let doorX = max(64, hubX - 215)
        return CGPoint(x: doorX, y: roomHeight - wallHeight)
    }

    /// 正面エントランス手前の横通路の高さ (Y)
    var topHallwayY: CGFloat {
        roomHeight - wallHeight - 20
    }

    /// 正面エントランス扉の真正面
    var doorFront: CGPoint {
        CGPoint(x: doorPosition.x, y: topHallwayY)
    }

    /// 正面エントランス扉の中（スポーン／消失位置）
    var doorSpawn: CGPoint {
        CGPoint(x: doorPosition.x, y: doorPosition.y + 12)
    }

    /// ツール別ホワイトボードの配置位置一覧。
    /// 正面エントランス扉（hubX - 215）の右側、および人間（hubX）を挟む形でツールごとに並べる。
    func whiteboardPositions(count: Int) -> [CGPoint] {
        guard count > 0 else { return [] }
        let hubX = roomWidth / 2
        // 壁面中央（全高80pt）の高さに掛け金具とともに配置する
        let boardY = roomHeight - wallHeight / 2 - 2

        if count == 1 {
            return [CGPoint(x: hubX + 105, y: boardY)]
        }

        var points: [CGPoint] = []
        // 1枚目（Claude）: 人間の左側（扉 hubX - 215 と 人間 hubX の中間）
        points.append(CGPoint(x: hubX - 100, y: boardY))

        // 2枚目（Antigravity）: 人間の右側
        points.append(CGPoint(x: hubX + 100, y: boardY))

        // 3枚目以降（Codex や複数アカウント）: 右側へ順に展開
        for i in 2..<count {
            let x = hubX + 100 + CGFloat(i - 1) * 155
            points.append(CGPoint(x: x, y: boardY))
        }
        return points
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

    /// 各行において人間（中央の見出し机）に近い順に並べた列インデックスの配列。
    /// ウィンドウを大きくした際も、中央の人間の目の前から左右交互に外側へと席を埋めていく。
    static func columnOrder(seatColumns: Int) -> [Int] {
        guard seatColumns > 1 else { return [0] }
        let center = CGFloat(seatColumns - 1) / 2.0
        return (0..<seatColumns).sorted { a, b in
            let distA = abs(CGFloat(a) - center)
            let distB = abs(CGFloat(b) - center)
            if abs(distA - distB) < 0.001 {
                // 距離が同じ（左右対称）の場合は、左側から順に配置する
                return a < b
            }
            return distA < distB
        }
    }

    /// 島の中の机の位置。上の段から、人間（中央の hub 机）に近い列から順に配置していく
    func seatPoint(island: Int, index: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        let spread = columnPitch * CGFloat(seatColumns - 1)
        let row = index / seatColumns
        let col = Self.columnOrder(seatColumns: seatColumns)[index % seatColumns]
        return CGPoint(x: hub.x - spread / 2 + columnPitch * CGFloat(col),
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
        let approachY = target.y + 26
        let row = seatIndex / seatColumns

        var points: [CGPoint] = []

        // 1. 扉の正面（上部横通路）へ出る
        points.append(doorFront)

        if row == 0 {
            // 最前列（Row 0）の席の背後は北壁との間の広い空間のため、上部横通路から直接自分の列へ進入できる
            if abs(doorFront.x - target.x) >= 4 {
                points.append(CGPoint(x: target.x, y: topHallwayY))
            }
            if abs(topHallwayY - approachY) >= 4 {
                points.append(CGPoint(x: target.x, y: approachY))
            }
        } else {
            // 後続列（Row 1 以降）へは、前列の机を横切らないよう西側の主通路を回り込んで進む
            let aisleX = min(doorFront.x - 24, col0X - (deskWidth / 2 + 36))
            if abs(doorFront.x - aisleX) >= 4 {
                points.append(CGPoint(x: aisleX, y: topHallwayY))
            }
            if abs(topHallwayY - approachY) >= 4 {
                points.append(CGPoint(x: aisleX, y: approachY))
            }
            if abs(aisleX - target.x) >= 4 {
                points.append(CGPoint(x: target.x, y: approachY))
            }
        }

        // 椅子に着席する（南へ一歩進む）
        points.append(target)

        return points
    }

    /// 机の前や待機列から正面エントランス扉への歩行ルート
    func departureWaypoints(from start: CGPoint) -> [CGPoint] {
        let hubX = roomWidth / 2
        let col0X = hubX - columnPitch * CGFloat(seatColumns - 1) / 2
        let approachY = start.y + 26
        let hub = hubPoint(island: 0)
        let isRow0OrAbove = start.y >= hub.y - hubRowSpacing

        var points: [CGPoint] = []

        // 1. 椅子から後ろ（北）へ一歩下がり、背後通路へ出る（机やモニタを突っ切らない）
        points.append(CGPoint(x: start.x, y: approachY))

        if isRow0OrAbove {
            // 最前列（Row 0）または待機列からは直接扉へ向かえる
            if abs(start.x - doorFront.x) >= 4 {
                points.append(CGPoint(x: doorFront.x, y: approachY))
            }
            if abs(approachY - topHallwayY) >= 4 {
                points.append(doorFront)
            }
        } else {
            // 後続列からは西側南北主通路へ横移動して北上する
            let aisleX = min(doorFront.x - 24, col0X - (deskWidth / 2 + 36))
            if abs(start.x - aisleX) >= 4 {
                points.append(CGPoint(x: aisleX, y: approachY))
            }
            if abs(approachY - topHallwayY) >= 4 {
                points.append(CGPoint(x: aisleX, y: topHallwayY))
            }
            if abs(aisleX - doorFront.x) >= 4 {
                points.append(doorFront)
            }
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
