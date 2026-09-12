import CoreGraphics
import Foundation

// MARK: - 間取りの見せ方

/// 間取りをどこまで出すか。サイドバーとオフィス窓で見せるものを変える。
///
/// サイドバーは幅 180pt まで細くできるので、西側のラウンジまで置くと
/// 「常に画面外にラウンジがある」状態になってパンし続けることになる。
/// 狭いほうでは区画の境目だけを示し、広いオフィス窓でだけ全体を出す
enum OfficeLayoutStyle {
    /// サイドバー。壁もラウンジも出さず、区画の境目をプランターだけで示す
    case compact
    /// オフィス窓。スイートの壁・共用ラウンジ・側面扉まで出す
    case suites

    var showsWalls: Bool { self == .suites }
    var showsLounge: Bool { self == .suites }
}

// MARK: - 実寸

/// 机まわりの実寸。`DeskFurnitureNode` と `DeskWhiteboardNode` の描画から起こした値で、
/// 部屋の大きさはすべてここから逆算する。
///
/// 横幅を決めているのが天板（184pt）ではなく**連続帳票用紙（226pt）**であること、
/// 高さの上端を決めているのが机ではなく**背後の自立ホワイトボード**であることに注意。
/// 見た目を変えずに間取りだけ組み替えるため、この数値は描画側と必ず一致させる
enum OfficeMetrics {
    /// 席の机1つが床に占める幅（連続帳票用紙の幅）
    static let seatCellWidth: CGFloat = 226
    /// 机の中心から上端（自立ホワイトボードの天面）まで
    static let seatCellTop: CGFloat = 115
    /// 机の中心から下端（連続帳票用紙の末端）まで
    static let seatCellBottom: CGFloat = 76
    /// ハブ机の中心から上端（自立ホワイトボードの天面）まで
    static let hubCellTop: CGFloat = 117
    /// ハブ机の中心から下端（天板の前面）まで
    static let hubCellBottom: CGFloat = 21

    /// ハブ机から最初の席の行までの間隔
    static let hubRowSpacing: CGFloat = 145
    /// 席の行と行の間隔
    static let rowSpacing: CGFloat = 185
    /// 席の列と列の最小間隔（連続帳票用紙 226pt ＋ 隙間 16pt）
    static let minColumnPitch: CGFloat = 242

    /// 区画の中身と区画枠の間に取る余白
    static let zonePadding: CGFloat = 24
    /// 区画と区画の間に挟む縦プランター帯の幅
    static let verticalPlanterGap: CGFloat = 56
    /// 区画と区画の間に挟む横プランター帯の高さ
    static let horizontalPlanterGap: CGFloat = 48
    /// スイートの壁の内側に取る通路
    static let wallInset: CGFloat = 32
    /// 組織銘板を掲げる奥壁の帯の高さ
    static let plateBand: CGFloat = 38
    /// 出入口だけがある側の壁の厚み
    static let doorBand: CGFloat = 12
    /// スイートとスイートの間を通す中央廊下
    static let centralCorridor: CGFloat = 52

    /// 西側の共用ラウンジの幅。状態ディスプレイの数字が窮屈にならない幅を取る
    static let loungeWidth: CGFloat = 280
    /// ラウンジとスイートの間の縦通路
    static let loungeCorridor: CGFloat = 48

    // ラウンジの中身。スイートの高さに合わせて伸ばすと、床が縦に長いときに
    // ソファだけが遠くの下端に取り残される。中身ぶんの高さに詰めて上端に揃える
    static let loungePadding: CGFloat = 10
    static let loungeGap: CGFloat = 8
    static let loungeHeaderHeight: CGFloat = 26
    static let loungeBarHeight: CGFloat = 26
    static let loungeSofaHeight: CGFloat = 40

    /// 状態ディスプレイ1枚の高さ
    static let loungeDisplayHeight: CGFloat = 50
    static let loungeDisplayGap: CGFloat = 6
    /// 状態ディスプレイの枚数（確認待ち・作業中・休憩中）
    static let loungeDisplayCount = 3

    /// 確認待ちディスプレイに出す明細1件の高さ
    static let loungeDetailRowHeight: CGFloat = 27
    /// 明細の行数。件数で高さを変えると台帳が動くたびに部屋を組み直すことになるので、
    /// 枠は固定にして、あふれたぶんは件数でまとめる
    static let loungeDetailRows = 3

    /// 確認待ちディスプレイの高さ。見出しの下に明細を抱える
    static var loungeAttentionDisplayHeight: CGFloat {
        loungeDisplayHeight + loungeDetailRowHeight * CGFloat(loungeDetailRows) + 8
    }

    /// 状態ディスプレイをまとめた高さ
    static var loungeBoardHeight: CGFloat {
        loungeAttentionDisplayHeight
            + loungeDisplayHeight * CGFloat(loungeDisplayCount - 1)
            + loungeDisplayGap * CGFloat(loungeDisplayCount - 1)
    }

    /// ラウンジの高さ。中身を上から下へ積んだぶんだけ
    static var loungeHeight: CGFloat {
        loungePadding * 2
            + loungeHeaderHeight + loungeBoardHeight + loungeBarHeight + loungeSofaHeight
            + loungeGap * 3
    }

    /// ラウンジの下端からソファの座面までの高さ
    static var loungeSofaOffset: CGFloat {
        loungePadding + loungeSofaHeight / 2
    }
    /// 部屋の外周に取る余白
    static let floorMargin: CGFloat = 32
    /// 北壁の高さ
    static let wallHeight: CGFloat = 80
    /// 北壁のすぐ下に取る横通路
    static let topHallway: CGFloat = 20
    /// 部屋の南端に取る余白
    static let bottomMargin: CGFloat = 60

    /// 側面扉の高さ（歩いて抜けられる開口）
    static let sideDoorHeight: CGFloat = 44
    /// スイートの出入口の幅
    static let suiteDoorWidth: CGFloat = 90
}

// MARK: - 間取り

/// オフィスの間取り。台帳の島（Repo）から1回だけ組み、以降は座標を引くだけにする。
///
/// SpriteKit に依存しない純粋な幾何なので、描画を差し替えても計算はそのまま使える
struct OfficeFloorPlan {
    /// リポジトリ1つ分の区画
    struct RepoZone {
        /// `[DeskIsland]` への索引。既存の呼び出し側はこの番号で座標を引く
        let islandIndex: Int
        let repo: String
        /// 区画の枠（プランターや区画ボードはこの縁に置く）
        let frame: CGRect
        let hubPoint: CGPoint
        let seatPoints: [CGPoint]

        /// 区画の西側を南北に走る通路。机の左端（枠から 24pt 内側）に当たらない位置
        var westAisleX: CGFloat { frame.minX + 12 }
        /// ハブ机の背後を東西に走る通路
        var northLaneY: CGFloat { frame.maxY - 18 }
    }

    /// 区画の境目に置くプランター帯
    struct Planter {
        let frame: CGRect
        let isVertical: Bool
    }

    /// 組織1つ分のスイート（個室）
    struct Suite {
        let orgKey: String
        let orgName: String
        let frame: CGRect
        let zones: [RepoZone]
        let planters: [Planter]
        /// 出入口の中心 X（北壁の中央）
        let doorX: CGFloat
        /// 出入口の Y（北壁の高さ）
        let doorY: CGFloat
        /// スイートの西端を南北に貫く通路。どの行の区画へもここから入る
        let aisleX: CGFloat
        /// 扉を入ってすぐの東西通路
        let entryLaneY: CGFloat
        /// 西壁の側面扉の中心 Y。区画の行ごとに1つ
        let sideDoorYs: [CGFloat]
        /// 組織銘板の帯の矩形（南奥壁）
        let plateBand: CGRect
    }

    /// 西側の共用ラウンジ
    struct Lounge {
        let frame: CGRect
        /// 東側の出入口の中心 Y。ソファと同じ高さに開けて、入ってすぐ座れるようにする
        let doorY: CGFloat
        /// ソファの座面。休憩中のエージェントが座る位置
        let sofaSpots: [CGPoint]
    }

    let size: CGSize
    let style: OfficeLayoutStyle
    let suites: [Suite]
    let lounge: Lounge?
    /// 席の列数（区画1つの中に何列の机を並べるか）
    let seatColumns: Int
    /// 区画の列数（スイート1つの中に何列の区画を並べるか）
    let zoneColumns: Int
    let columnPitch: CGFloat
    /// 島の索引から区画を引くための表
    private let zonesByIsland: [Int: RepoZone]

    /// スイート群の水平方向の中心。北壁の扉やレート上限ボードはこの上に載せる
    let contentCenterX: CGFloat
    /// スイートの西側を南北に貫く主通路。北壁の扉から各スイートの扉まではここを通る
    let mainAisleX: CGFloat

    /// 北壁のすぐ下を東西に走る通路
    var topHallwayY: CGFloat {
        size.height - OfficeMetrics.wallHeight - OfficeMetrics.topHallway
    }

    func zone(island: Int) -> RepoZone? { zonesByIsland[island] }

    /// 島がどのスイートに属するか
    func suite(island: Int) -> Suite? {
        suites.first { $0.zones.contains { $0.islandIndex == island } }
    }
}

// MARK: - 組み立て

extension OfficeFloorPlan {
    /// 台帳の島とビューポートの大きさから間取りを組む。
    ///
    /// - Parameters:
    ///   - islands: 組織順に並んだ島（`DeskIslands.build` の出力）
    ///   - viewport: 表示領域の大きさ。ここから列数のバジェットを決める
    ///   - style: 壁とラウンジを出すかどうか
    ///   - minContentWidth: 北壁に並ぶボードが見切れないための最小幅
    static func build(islands: [DeskIsland],
                      viewport: CGSize,
                      style: OfficeLayoutStyle,
                      minContentWidth: CGFloat = 0,
                      noOrganizationName: String) -> OfficeFloorPlan {
        // 組織ごとに島をまとめる。`DeskIslands.build` が組織順に並べてくれているので、
        // ここでは隣り合う同じ組織を束ねるだけで済む
        var groups: [(key: String, name: String, indices: [Int])] = []
        for (index, island) in islands.enumerated() {
            let key = island.organizationKey
            if var last = groups.last, last.key == key {
                last.indices.append(index)
                groups[groups.count - 1] = last
            } else {
                groups.append((key, island.organizationName ?? noOrganizationName, [index]))
            }
        }

        // 列数のバジェットを、区画の列と席の列で分け合う。
        // Repo が1つのときは席がすべての列を取るので、これまでの見え方がそのまま残る
        let budget = max(1, min(6, Int(viewport.width / 245)))
        let maxZones = groups.map(\.indices.count).max() ?? 1
        let zoneColumns = max(1, min(budget, Int(ceil(Double(maxZones).squareRoot()))))

        // 列の間隔はバジェットぶんの列数から出す。実際に使う列数で割ってしまうと、
        // 席が1つしかないときに机同士が窓幅いっぱいまで離れてしまう
        let pitchColumns = max(1, budget / zoneColumns)
        let columnPitch = max(OfficeMetrics.minColumnPitch,
                              (viewport.width - 24) / CGFloat(pitchColumns * zoneColumns))

        // 実際に使う列数は席の数までに抑える。席1つに3列ぶんの幅を取ると、
        // 区画の左右が空きカーペットになる
        let maxSeats = islands.map(\.seats.count).max() ?? 0
        let seatColumns = max(1, min(pitchColumns, maxSeats))

        // 区画1つの幅は席の列数だけで決まるので、どの区画も同じ幅になる
        let zoneWidth = OfficeMetrics.seatCellWidth
            + columnPitch * CGFloat(seatColumns - 1)
            + OfficeMetrics.zonePadding * 2

        let showsWalls = style.showsWalls
        let wallInset = showsWalls ? OfficeMetrics.wallInset : 0
        let doorBandHeight = showsWalls ? OfficeMetrics.doorBand : 0
        // 組織銘板の帯は壁を出さないときも残す。
        // 壁が無いと組織の切れ目を示すものが何も無くなり、どこからどこまでが
        // 同じ組織なのか分からなくなるため
        let plateBandHeight = OfficeMetrics.plateBand

        // 各スイートの中身の高さを先に出す（部屋全体の高さが要るため）
        func seatRows(_ index: Int) -> Int {
            let count = islands[index].seats.count
            guard count > 0 else { return 0 }
            return (count + seatColumns - 1) / seatColumns
        }

        func zoneHeight(_ index: Int) -> CGFloat {
            let rows = seatRows(index)
            let content: CGFloat
            if rows == 0 {
                content = OfficeMetrics.hubCellTop + OfficeMetrics.hubCellBottom
            } else {
                content = OfficeMetrics.hubCellTop
                    + OfficeMetrics.hubRowSpacing
                    + OfficeMetrics.rowSpacing * CGFloat(rows - 1)
                    + OfficeMetrics.seatCellBottom
            }
            return content + OfficeMetrics.zonePadding * 2
        }

        /// 区画の行ごとの高さ。行の中で一番高い区画に合わせ、プランターを一直線に通す
        func rowHeights(_ indices: [Int]) -> [CGFloat] {
            let rows = (indices.count + zoneColumns - 1) / zoneColumns
            return (0..<rows).map { row in
                let slice = indices.enumerated()
                    .filter { $0.offset / zoneColumns == row }
                    .map { zoneHeight($0.element) }
                return slice.max() ?? 0
            }
        }

        let suiteInnerWidth = zoneWidth * CGFloat(zoneColumns)
            + OfficeMetrics.verticalPlanterGap * CGFloat(zoneColumns - 1)
        let suiteWidth = suiteInnerWidth + wallInset * 2

        let suiteHeights: [CGFloat] = groups.map { group in
            let heights = rowHeights(group.indices)
            let inner = heights.reduce(0, +)
                + OfficeMetrics.horizontalPlanterGap * CGFloat(max(0, heights.count - 1))
            return inner + wallInset * 2 + plateBandHeight + doorBandHeight
        }

        // 部屋の大きさ
        let loungeWidth = style.showsLounge ? OfficeMetrics.loungeWidth : 0
        let loungeCorridor = style.showsLounge ? OfficeMetrics.loungeCorridor : 0
        let contentLeft = OfficeMetrics.floorMargin + loungeWidth + loungeCorridor
        let naturalWidth = contentLeft + suiteWidth + OfficeMetrics.floorMargin
        let roomWidth = max(naturalWidth, minContentWidth)

        let northBand = OfficeMetrics.wallHeight + OfficeMetrics.topHallway
        let suitesHeight = suiteHeights.reduce(0, +)
            + OfficeMetrics.centralCorridor * CGFloat(max(0, suiteHeights.count - 1))
        let roomHeight = max(viewport.height,
                             northBand + suitesHeight + OfficeMetrics.bottomMargin)

        // スイートを北から順に積む。中身の幅が部屋より狭いときは、
        // ラウンジの右側の残りに対して中央に寄せる
        let suiteX = contentLeft + max(0, (roomWidth - contentLeft - OfficeMetrics.floorMargin - suiteWidth) / 2)
        var cursorY = roomHeight - northBand
        var suites: [Suite] = []
        var zonesByIsland: [Int: RepoZone] = [:]

        for (groupIndex, group) in groups.enumerated() {
            let suiteHeight = suiteHeights[groupIndex]
            let suiteFrame = CGRect(x: suiteX, y: cursorY - suiteHeight,
                                    width: suiteWidth, height: suiteHeight)

            // 出入口は必ず北壁、組織銘板は必ず南奥壁に置く。
            // 扉から入ると正面奥に組織名が見えるという関係を、組織が何個あっても崩さないため。
            // 上下で鏡写しにすると見た目は対称になるが、北の組織へ入るのに部屋を回り込む
            // 動線になってしまい、組織が3つ以上のときに破綻する
            let plateBand = CGRect(x: suiteFrame.minX, y: suiteFrame.minY,
                                   width: suiteWidth, height: plateBandHeight)
            let innerTop = suiteFrame.maxY - doorBandHeight - wallInset
            let doorY = suiteFrame.maxY

            let heights = rowHeights(group.indices)
            var zones: [RepoZone] = []
            var planters: [Planter] = []
            var sideDoorYs: [CGFloat] = []
            var rowTop = innerTop

            for (row, rowHeight) in heights.enumerated() {
                for column in 0..<zoneColumns {
                    let slot = row * zoneColumns + column
                    guard slot < group.indices.count else { continue }
                    let islandIndex = group.indices[slot]

                    let zoneX = suiteFrame.minX + wallInset
                        + (zoneWidth + OfficeMetrics.verticalPlanterGap) * CGFloat(column)
                    let frame = CGRect(x: zoneX, y: rowTop - rowHeight,
                                       width: zoneWidth, height: rowHeight)

                    let centerX = frame.midX
                    let hubY = frame.maxY - OfficeMetrics.zonePadding - OfficeMetrics.hubCellTop
                    let hub = CGPoint(x: centerX, y: hubY)

                    let spread = columnPitch * CGFloat(seatColumns - 1)
                    let order = DeskLayout.columnOrder(seatColumns: seatColumns)
                    let seats = (0..<islands[islandIndex].seats.count).map { index -> CGPoint in
                        let seatRow = index / seatColumns
                        let seatCol = order[index % seatColumns]
                        return CGPoint(x: centerX - spread / 2 + columnPitch * CGFloat(seatCol),
                                       y: hubY - OfficeMetrics.hubRowSpacing
                                           - OfficeMetrics.rowSpacing * CGFloat(seatRow))
                    }

                    let zone = RepoZone(islandIndex: islandIndex,
                                        repo: islands[islandIndex].repo,
                                        frame: frame,
                                        hubPoint: hub,
                                        seatPoints: seats)
                    zones.append(zone)
                    zonesByIsland[islandIndex] = zone

                    // 左隣の区画との境目に縦プランターを立てる。
                    // 上端を 36pt 空けておくのは、区画の北側の通路（`northLaneY`）を塞がないため
                    if column > 0 {
                        let gapX = frame.minX - OfficeMetrics.verticalPlanterGap
                        planters.append(Planter(
                            frame: CGRect(x: gapX + 10, y: frame.minY + 10,
                                          width: OfficeMetrics.verticalPlanterGap - 20,
                                          height: max(20, rowHeight - 46)),
                            isVertical: true))
                    }
                }

                // 上の行との境目に横プランターを渡す。
                // 西端を 30pt 空けておくのは、スイートを南北に貫く主通路を塞がないため
                if row > 0 {
                    let laneX = suiteFrame.minX + wallInset + 30
                    planters.append(Planter(
                        frame: CGRect(x: laneX,
                                      y: rowTop + 8,
                                      width: suiteInnerWidth - 30,
                                      height: OfficeMetrics.horizontalPlanterGap - 16),
                        isVertical: false))
                }

                // 行ごとに西壁の側面扉を開ける。区画が縦に伸びても数歩でラウンジへ抜けられる
                if style.showsLounge {
                    let doorCenterY = rowTop - rowHeight / 2
                    sideDoorYs.append(doorCenterY)
                }

                rowTop -= rowHeight + OfficeMetrics.horizontalPlanterGap
            }

            suites.append(Suite(orgKey: group.key,
                                orgName: group.name,
                                frame: suiteFrame,
                                zones: zones,
                                planters: planters,
                                doorX: suiteFrame.midX,
                                doorY: doorY,
                                aisleX: suiteFrame.minX + wallInset + 12,
                                entryLaneY: zones.first?.northLaneY ?? innerTop,
                                sideDoorYs: sideDoorYs,
                                plateBand: plateBand))

            cursorY = suiteFrame.minY - OfficeMetrics.centralCorridor
        }

        // 西側の共用ラウンジ。中身ぶんの高さに詰めて、一番北のスイートと上端を揃える。
        // スイートの縦の範囲いっぱいに伸ばすと、リポジトリが増えて床が縦に長くなるほど
        // ソファが遠くの下端へ離れていってしまう
        var lounge: Lounge?
        if style.showsLounge, let first = suites.first {
            let height = OfficeMetrics.loungeHeight
            let frame = CGRect(x: OfficeMetrics.floorMargin,
                               y: first.frame.maxY - height,
                               width: OfficeMetrics.loungeWidth,
                               height: height)
            let sofaY = frame.minY + OfficeMetrics.loungeSofaOffset
            let sofaSpots = [
                CGPoint(x: frame.midX - 34, y: sofaY),
                CGPoint(x: frame.midX, y: sofaY),
                CGPoint(x: frame.midX + 34, y: sofaY)
            ]
            lounge = Lounge(frame: frame, doorY: sofaY, sofaSpots: sofaSpots)
        }

        let centerX = suites.first?.frame.midX ?? roomWidth / 2
        // 主通路はスイートの西側。ラウンジがあるならその間の通路、無ければスイートのすぐ左を通す
        let mainAisleX = lounge.map { $0.frame.maxX + OfficeMetrics.loungeCorridor / 2 }
            ?? max(12, suiteX - 16)

        return OfficeFloorPlan(size: CGSize(width: roomWidth, height: roomHeight),
                               style: style,
                               suites: suites,
                               lounge: lounge,
                               seatColumns: seatColumns,
                               zoneColumns: zoneColumns,
                               columnPitch: columnPitch,
                               zonesByIsland: zonesByIsland,
                               contentCenterX: centerX,
                               mainAisleX: mainAisleX)
    }
}
