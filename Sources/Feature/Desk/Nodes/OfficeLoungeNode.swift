import AppKit
import Foundation
import Model
import Resources
import SpriteKit

/// 全組織で共用する西側の休憩ラウンジ。
///
/// 区画ごとにソファを置くとリポジトリが増えるたびに横幅が膨らむので、
/// スイートの外に1つだけ置いて全員で使う。
/// 上から順に、案内板・状態ディスプレイ・ドリンクバー・ソファを並べる。
///
/// 状態ディスプレイはサイドバーの状態タブと同じ切り方（確認待ち・作業中・休憩中）で数を出す。
/// 見る場所が違っても数が食い違わないよう、区切り方は `TaskGrouping.byStatus` に合わせてある
/// （`FeatureSidebar` は `FeatureDesk` に依存する側なので、型は借りずに判定だけ揃えている）
final class OfficeLoungeNode: SKNode {
    // MARK: - 状態の区分

    /// ディスプレイに出す区分。並びはサイドバーの状態タブと同じ
    enum Board: Int, CaseIterable {
        case needsPerson
        case working
        case resting

        var titleKey: String {
            switch self {
            case .needsPerson: return "app.office.lounge.needs_person"
            case .working: return "app.office.lounge.working"
            case .resting: return "app.office.lounge.resting"
            }
        }

        /// 机のモニタや自立ホワイトボードで使っている状態色に合わせる
        var tint: NSColor {
            switch self {
            case .needsPerson: return NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 1.0)
            case .working: return NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 1.0)
            case .resting: return NSColor(red: 0.400, green: 0.733, blue: 0.416, alpha: 1.0)
            }
        }
    }

    /// 席1つがどの区分に入るか。
    ///
    /// 人の手が要るかを先に見るのは、サイドバーの状態タブと同じ順序。
    /// ここに独自の条件を書くと、同じ台帳を見ているのに数が合わなくなる
    static func board(for seat: DeskSeat) -> Board {
        if seat.needsPerson { return .needsPerson }
        if seat.status == TaskStatus.running { return .working }
        return .resting
    }
    // MARK: - 重なり順

    static let carpetZ: CGFloat = -9800
    static let furnitureZ: CGFloat = -9700

    // MARK: - 寸法

    // 間取りが同じ数値でラウンジの高さを出しているので、必ず `OfficeMetrics` を引く。
    // ここで別の値を持つと、箱の高さと中身の積み上げがずれる
    private static let padding = OfficeMetrics.loungePadding
    private static let gap = OfficeMetrics.loungeGap
    private static let headerHeight = OfficeMetrics.loungeHeaderHeight
    private static let boardHeight = OfficeMetrics.loungeBoardHeight
    private static let displayHeight = OfficeMetrics.loungeDisplayHeight
    private static let displayGap = OfficeMetrics.loungeDisplayGap
    private static let barHeight = OfficeMetrics.loungeBarHeight
    private static let sofaHeight = OfficeMetrics.loungeSofaHeight

    // MARK: - 色

    static let accentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.85, green: 0.71, blue: 0.31, alpha: 1.0)
            : NSColor(red: 0.62, green: 0.47, blue: 0.10, alpha: 1.0)
    }

    static let carpetColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.16, green: 0.14, blue: 0.11, alpha: 0.55)
            : NSColor(red: 0.93, green: 0.90, blue: 0.84, alpha: 0.55)
    }

    static let woodColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.21, green: 0.16, blue: 0.11, alpha: 0.95)
            : NSColor(red: 0.72, green: 0.63, blue: 0.51, alpha: 0.95)
    }

    /// ディスプレイの外枠。画面まわりは明暗どちらでも暗くして、画面を光って見せる
    static let bezelColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 0.98)
            : NSColor(white: 0.24, alpha: 0.98)
    }

    /// 件数が 0 のディスプレイ。電源が落ちているように見せる
    static let panelOffColor = NSColor(white: 0.07, alpha: 0.92)

    /// 画面に載る文字。地が暗いので明暗どちらでも明るい側で置く
    static let boardInkColor = NSColor(white: 0.86, alpha: 1.0)

    static let sofaColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.16, green: 0.28, blue: 0.20, alpha: 1.0)
            : NSColor(red: 0.42, green: 0.58, blue: 0.45, alpha: 1.0)
    }

    static let sofaSeatColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.22, green: 0.38, blue: 0.27, alpha: 1.0)
            : NSColor(red: 0.55, green: 0.71, blue: 0.58, alpha: 1.0)
    }

    // MARK: - 更新できる部品

    /// 各ディスプレイの件数表示
    private var counters: [Board: SKLabelNode] = [:]
    /// 各ディスプレイの画面。件数が 0 のときは暗く落とす
    private var panels: [Board: SKShapeNode] = [:]
    /// 確認待ちディスプレイの明細行（1行目: 何を待たせているか／2行目: 待っている内容）
    private var detailTitles: [SKLabelNode] = []
    private var detailBodies: [SKLabelNode] = []

    /// 確認待ちの明細1件
    struct Attention {
        let name: String
        let repo: String
        /// 待っている内容。承認要求または締めのメッセージ
        let request: String?
    }

    // MARK: - 初期化

    init(lounge: OfficeFloorPlan.Lounge) {
        super.init()

        name = "lounge"
        position = lounge.frame.origin
        zPosition = Self.carpetZ

        let width = lounge.frame.width
        let height = lounge.frame.height

        addChild(carpet(width: width, height: height))

        // 上端から順に積む。箱の高さは `OfficeMetrics.loungeHeight` がこれと同じ順で出している
        var cursor = height - Self.padding
        cursor -= Self.headerHeight
        addChild(header(width: width, y: cursor))

        cursor -= Self.gap + Self.boardHeight
        addChild(displays(width: width, y: cursor))

        cursor -= Self.gap + Self.barHeight
        addChild(drinkBar(width: width, y: cursor))

        cursor -= Self.gap + OfficeMetrics.loungeTableAreaHeight
        addChild(tables(centers: lounge.tableCenters.map {
            CGPoint(x: $0.x - lounge.frame.minX, y: $0.y - lounge.frame.minY)
        }))

        cursor -= Self.gap + Self.sofaHeight
        addChild(sofa(width: width, y: cursor,
                      spots: lounge.seatSpots.prefix(OfficeMetrics.loungeSofaSeats)
                          .map { $0.x - lounge.frame.minX }))

        // 東側の出入口。ソファと同じ高さに開けて、入ってすぐ座れるようにする
        addChild(doorway(at: CGPoint(x: width, y: lounge.doorY - lounge.frame.minY)))

        setCounts([:], attention: [])
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 状態の反映

    /// 状態ごとの件数と、確認待ちの明細をディスプレイに出す
    func setCounts(_ counts: [Board: Int], attention: [Attention]) {
        for board in Board.allCases {
            let count = counts[board] ?? 0
            counters[board]?.text = "\(count)"
            // 0 のディスプレイは電源が落ちているように見せる。
            // 全部同じ明るさだと、いま何が起きているのかが一目で読めない
            counters[board]?.fontColor = count > 0
                ? board.tint
                : Self.boardInkColor.withAlphaComponent(0.35)
            panels[board]?.fillColor = count > 0
                ? board.tint.withAlphaComponent(0.14)
                : Self.panelOffColor
            panels[board]?.strokeColor = count > 0
                ? board.tint.withAlphaComponent(0.75)
                : Self.boardInkColor.withAlphaComponent(0.25)
        }

        // 枠に収まらないぶんは最終行を「あと N 件」に使う
        let capacity = detailTitles.count
        let overflows = attention.count > capacity
        let shown = overflows ? Array(attention.prefix(capacity - 1)) : attention
        let tint = Board.needsPerson.tint

        for index in 0..<capacity {
            let title = detailTitles[index]
            let body = detailBodies[index]

            if index < shown.count {
                let entry = shown[index]
                title.text = Self.truncate("\(entry.name)  \(entry.repo)", limit: 30)
                title.fontColor = Self.boardInkColor
                body.text = entry.request.map { Self.truncate($0, limit: 36) } ?? ""
                body.fontColor = tint.withAlphaComponent(0.85)
            } else if overflows && index == capacity - 1 {
                title.text = "+\(attention.count - shown.count)"
                title.fontColor = Self.boardInkColor.withAlphaComponent(0.7)
                body.text = ""
            } else {
                title.text = ""
                body.text = ""
            }
        }
    }

    /// 画面幅に収まらない文字を後ろから詰める
    private static func truncate(_ text: String, limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)) + "…"
    }

    // MARK: - 部品

    private func carpet(width: CGFloat, height: CGFloat) -> SKNode {
        let node = SKNode()

        let base = SKShapeNode(rect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 8)
        base.fillColor = Self.carpetColor
        base.strokeColor = Self.accentColor.withAlphaComponent(0.5)
        base.lineWidth = 1.2
        node.addChild(base)

        return node
    }

    private func header(width: CGFloat, y: CGFloat) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: 0, y: y)
        node.zPosition = Self.furnitureZ - Self.carpetZ

        let band = SKShapeNode(rect: CGRect(x: 0, y: 0, width: width, height: Self.headerHeight),
                               cornerRadius: 6)
        band.fillColor = Self.woodColor
        band.strokeColor = .clear
        node.addChild(band)

        let label = SKLabelNode(text: Localized.text("app.office.lounge.title"))
        label.fontName = "Menlo-Bold"
        label.fontSize = 9.5
        label.fontColor = Self.accentColor
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 14, y: Self.headerHeight / 2)
        node.addChild(label)

        return node
    }

    /// 状態ごとの巨大ディスプレイ。壁掛けモニタを縦に3枚並べたつもりで描く。
    ///
    /// 確認待ちだけは見出しの下に明細を抱えて背が高い。数だけ出しても
    /// 「何を待たせているのか」が分からず、結局セッションを開いて回ることになるため
    private func displays(width: CGFloat, y: CGFloat) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: 12, y: y)
        node.zPosition = Self.furnitureZ - Self.carpetZ

        let panelWidth = width - 24
        var top = Self.boardHeight

        for board in Board.allCases {
            let panelHeight = board == .needsPerson
                ? OfficeMetrics.loungeAttentionDisplayHeight
                : Self.displayHeight
            let rect = CGRect(x: 0, y: top - panelHeight, width: panelWidth, height: panelHeight)
            // 見出し（状態名と件数）は、明細があっても画面の上端に固定する
            let headRect = CGRect(x: rect.minX, y: rect.maxY - Self.displayHeight,
                                  width: panelWidth, height: Self.displayHeight)

            // 画面の外枠（ベゼル）
            let bezel = SKShapeNode(rect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 5)
            bezel.fillColor = Self.bezelColor
            bezel.strokeColor = .clear
            node.addChild(bezel)

            let panel = SKShapeNode(rect: rect, cornerRadius: 4)
            panel.lineWidth = 1.2
            panel.zPosition = 1
            node.addChild(panel)
            panels[board] = panel

            // 左端の状態色のバー。数字を読まなくても色で区別が付く
            let stripe = SKShapeNode(rect: CGRect(x: headRect.minX + 6, y: headRect.minY + 8,
                                                  width: 4, height: Self.displayHeight - 16),
                                     cornerRadius: 2)
            stripe.fillColor = board.tint
            stripe.strokeColor = .clear
            stripe.zPosition = 2
            node.addChild(stripe)

            let title = SKLabelNode(text: Localized.text(board.titleKey))
            title.fontName = "Menlo-Bold"
            title.fontSize = 11
            title.fontColor = Self.boardInkColor
            title.horizontalAlignmentMode = .left
            title.verticalAlignmentMode = .center
            title.position = CGPoint(x: headRect.minX + 18, y: headRect.midY)
            title.zPosition = 2
            node.addChild(title)

            let counter = SKLabelNode(text: "0")
            counter.fontName = "Menlo-Bold"
            counter.fontSize = 26
            counter.horizontalAlignmentMode = .right
            counter.verticalAlignmentMode = .center
            counter.position = CGPoint(x: headRect.maxX - 14, y: headRect.midY - 1)
            counter.zPosition = 2
            node.addChild(counter)
            counters[board] = counter

            if board == .needsPerson {
                addDetailRows(to: node, under: headRect, bottom: rect.minY)
            }

            top -= panelHeight + Self.displayGap
        }

        return node
    }

    /// 確認待ちディスプレイの明細行。見出しとの間に区切り線を1本引く
    private func addDetailRows(to node: SKNode, under headRect: CGRect, bottom: CGFloat) {
        let divider = SKShapeNode(rect: CGRect(x: headRect.minX + 8, y: headRect.minY - 1,
                                               width: headRect.width - 16, height: 1))
        divider.fillColor = Self.boardInkColor.withAlphaComponent(0.18)
        divider.strokeColor = .clear
        divider.zPosition = 2
        node.addChild(divider)

        let rowHeight = OfficeMetrics.loungeDetailRowHeight
        for index in 0..<OfficeMetrics.loungeDetailRows {
            let rowTop = headRect.minY - 4 - rowHeight * CGFloat(index)

            let title = SKLabelNode(text: "")
            title.fontName = "Menlo-Bold"
            title.fontSize = 9
            title.horizontalAlignmentMode = .left
            title.verticalAlignmentMode = .center
            title.position = CGPoint(x: headRect.minX + 12, y: rowTop - 8)
            title.zPosition = 2
            node.addChild(title)
            detailTitles.append(title)

            let body = SKLabelNode(text: "")
            body.fontName = "Menlo"
            body.fontSize = 8
            body.horizontalAlignmentMode = .left
            body.verticalAlignmentMode = .center
            body.position = CGPoint(x: headRect.minX + 18, y: rowTop - 19)
            body.zPosition = 2
            node.addChild(body)
            detailBodies.append(body)
        }
    }

    /// 給茶機とエスプレッソマシンが載ったカウンター
    private func drinkBar(width: CGFloat, y: CGFloat) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: 12, y: y)
        node.zPosition = Self.furnitureZ - Self.carpetZ

        let counter = SKShapeNode(rect: CGRect(x: 0, y: 0, width: width - 24, height: Self.barHeight),
                                  cornerRadius: 3)
        counter.fillColor = Self.woodColor
        counter.strokeColor = Self.accentColor.withAlphaComponent(0.35)
        counter.lineWidth = 0.8
        node.addChild(counter)

        // エスプレッソマシン
        let machine = SKShapeNode(rect: CGRect(x: 9, y: 4, width: 20, height: Self.barHeight - 8),
                                  cornerRadius: 2)
        machine.fillColor = NSColor(white: 0.86, alpha: 0.95)
        machine.strokeColor = NSColor(white: 0.55, alpha: 0.9)
        machine.lineWidth = 0.8
        machine.zPosition = 1
        node.addChild(machine)

        let lamp = SKShapeNode(circleOfRadius: 1.4)
        lamp.position = CGPoint(x: 14, y: Self.barHeight / 2)
        lamp.fillColor = NSColor(red: 0.85, green: 0.22, blue: 0.20, alpha: 1.0)
        lamp.strokeColor = .clear
        lamp.zPosition = 2
        node.addChild(lamp)

        // 給茶機
        let dispenser = SKShapeNode(rect: CGRect(x: 36, y: 3, width: 15, height: Self.barHeight - 6),
                                    cornerRadius: 2)
        dispenser.fillColor = Self.accentColor.withAlphaComponent(0.75)
        dispenser.strokeColor = .clear
        dispenser.zPosition = 1
        node.addChild(dispenser)

        // ずんだ餅の皿
        let plate = SKShapeNode(circleOfRadius: 5)
        plate.position = CGPoint(x: 63, y: Self.barHeight / 2)
        plate.fillColor = NSColor(white: 0.9, alpha: 0.95)
        plate.strokeColor = NSColor(white: 0.6, alpha: 0.8)
        plate.lineWidth = 0.6
        plate.zPosition = 1
        node.addChild(plate)

        for dx: CGFloat in [-2, 2] {
            let mochi = SKShapeNode(circleOfRadius: 2.1)
            mochi.position = CGPoint(x: 63 + dx, y: Self.barHeight / 2)
            mochi.fillColor = NSColor(red: 0.62, green: 0.82, blue: 0.42, alpha: 1.0)
            mochi.strokeColor = .clear
            mochi.zPosition = 2
            node.addChild(mochi)
        }

        return node
    }

    /// ソファ。背もたれを北側（上）に置き、座面を南向きにする
    private func sofa(width: CGFloat, y: CGFloat, spots: [CGFloat]) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: 16, y: y)
        node.zPosition = Self.furnitureZ - Self.carpetZ

        let sofaWidth = width - 32
        let frame = SKShapeNode(rect: CGRect(x: 0, y: 0, width: sofaWidth, height: Self.sofaHeight),
                                cornerRadius: 6)
        frame.fillColor = Self.sofaColor
        frame.strokeColor = Self.sofaSeatColor
        frame.lineWidth = 1.0
        node.addChild(frame)

        let seat = SKShapeNode(rect: CGRect(x: 6, y: 5, width: sofaWidth - 12, height: Self.sofaHeight - 14),
                               cornerRadius: 4)
        seat.fillColor = Self.sofaSeatColor
        seat.strokeColor = .clear
        seat.zPosition = 1
        node.addChild(seat)

        // 座面の割れ目。1人掛けがいくつ並んでいるかを示す
        for spot in spots.dropFirst() {
            let split = SKShapeNode(rect: CGRect(x: spot - 16 - 0.5, y: 6, width: 1,
                                                 height: Self.sofaHeight - 16))
            split.fillColor = Self.sofaColor
            split.strokeColor = .clear
            split.zPosition = 2
            node.addChild(split)
        }

        return node
    }

    /// 丸テーブルと、それを囲む椅子。ソファ3席では4人目から座れない
    private func tables(centers: [CGPoint]) -> SKNode {
        let node = SKNode()
        node.zPosition = Self.furnitureZ - Self.carpetZ

        for center in centers {
            // 椅子を先に描いて、天板を上に重ねる
            for index in 0..<OfficeMetrics.loungeTableSeats {
                let angle = CGFloat.pi / 2
                    - CGFloat(index) * (.pi * 2 / CGFloat(OfficeMetrics.loungeTableSeats))
                let seat = SKShapeNode(circleOfRadius: 7)
                seat.position = CGPoint(
                    x: center.x + cos(angle) * OfficeMetrics.loungeTableSeatRadius,
                    y: center.y + sin(angle) * OfficeMetrics.loungeTableSeatRadius)
                seat.fillColor = Self.sofaSeatColor
                seat.strokeColor = Self.sofaColor
                seat.lineWidth = 1.0
                node.addChild(seat)
            }

            let shadow = SKShapeNode(circleOfRadius: OfficeMetrics.loungeTableRadius)
            shadow.position = CGPoint(x: center.x + 1.5, y: center.y - 2.5)
            shadow.fillColor = .black.withAlphaComponent(0.18)
            shadow.strokeColor = .clear
            shadow.zPosition = 1
            node.addChild(shadow)

            let top = SKShapeNode(circleOfRadius: OfficeMetrics.loungeTableRadius)
            top.position = center
            top.fillColor = Self.woodColor
            top.strokeColor = Self.accentColor.withAlphaComponent(0.45)
            top.lineWidth = 1.0
            top.zPosition = 2
            node.addChild(top)

            // 天板の上のマグカップ
            let mug = SKShapeNode(circleOfRadius: 3)
            mug.position = CGPoint(x: center.x + 5, y: center.y + 3)
            mug.fillColor = NSColor(white: 0.9, alpha: 0.95)
            mug.strokeColor = NSColor(white: 0.55, alpha: 0.9)
            mug.lineWidth = 0.6
            mug.zPosition = 3
            node.addChild(mug)
        }

        return node
    }

    private func doorway(at point: CGPoint) -> SKNode {
        let node = SKNode()
        node.position = point
        node.zPosition = Self.furnitureZ - Self.carpetZ

        let sill = SKShapeNode(rect: CGRect(x: -2, y: -OfficeMetrics.sideDoorHeight / 2,
                                            width: 4, height: OfficeMetrics.sideDoorHeight),
                               cornerRadius: 1.5)
        sill.fillColor = Self.accentColor.withAlphaComponent(0.4)
        sill.strokeColor = Self.accentColor.withAlphaComponent(0.7)
        sill.lineWidth = 0.8
        node.addChild(sill)

        return node
    }
}
