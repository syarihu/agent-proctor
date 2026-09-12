import AppKit
import Foundation
import Resources
import SpriteKit

/// 全組織で共用する西側の休憩ラウンジ。
///
/// 区画ごとにソファを置くとリポジトリが増えるたびに横幅が膨らむので、
/// スイートの外に1つだけ置いて全員で使う。
/// 上から順に、案内板・休憩者のボード・ドリンクバー、そして下端にソファを並べる。
///
/// ソファを下端に吸着させているのは、スイートが縦に伸びてラウンジも一緒に伸びたときに、
/// 中身が上に固まって下半分が空カーペットになるのを避けるため
final class OfficeLoungeNode: SKNode {
    // MARK: - 重なり順

    static let carpetZ: CGFloat = -9800
    static let furnitureZ: CGFloat = -9700

    // MARK: - 寸法

    /// 案内板の帯の高さ
    private static let headerHeight: CGFloat = 30
    /// 休憩者ボードの高さ
    private static let boardHeight: CGFloat = 96
    /// ドリンクバーの高さ
    private static let barHeight: CGFloat = 26
    /// ソファの高さ
    private static let sofaHeight: CGFloat = 40

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

    static let boardColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.93, alpha: 0.96)
            : NSColor(white: 1.0, alpha: 0.98)
    }

    static let boardInkColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 1.0)
            : NSColor(white: 0.32, alpha: 1.0)
    }

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

    /// 休憩者ボードの本文。休憩中のエージェントに合わせて差し替える
    private let boardLines: [SKLabelNode]

    // MARK: - 初期化

    init(lounge: OfficeFloorPlan.Lounge) {
        var lines: [SKLabelNode] = []
        for _ in 0..<3 {
            let label = SKLabelNode(text: "")
            label.fontName = "Menlo"
            label.fontSize = 8
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.fontColor = Self.boardInkColor
            lines.append(label)
        }
        boardLines = lines

        super.init()

        name = "lounge"
        position = lounge.frame.origin
        zPosition = Self.carpetZ

        let width = lounge.frame.width
        let height = lounge.frame.height

        addChild(carpet(width: width, height: height))

        // 上から順に積む
        var cursor = height
        cursor -= Self.headerHeight
        addChild(header(width: width, y: cursor))

        cursor -= 10 + Self.boardHeight
        addChild(board(width: width, y: cursor))

        cursor -= 10 + Self.barHeight
        addChild(drinkBar(width: width, y: cursor))

        // ソファは下端に寄せる
        addChild(sofa(width: width, y: 30, spots: lounge.sofaSpots.map { $0.x - lounge.frame.minX }))

        // 東側の出入口。スイートの側面扉と向かい合う
        for doorY in lounge.doorYs {
            addChild(doorway(at: CGPoint(x: width, y: doorY - lounge.frame.minY)))
        }

        setResting([])
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 状態の反映

    /// 休憩中のエージェントの一覧をボードに書き出す
    func setResting(_ entries: [String]) {
        guard !entries.isEmpty else {
            boardLines[0].text = Localized.text("app.office.lounge.all_at_desk")
            for line in boardLines.dropFirst() { line.text = "" }
            return
        }

        // 行数に収まらないぶんは最終行に件数でまとめる
        let capacity = boardLines.count
        let overflows = entries.count > capacity
        let shown = overflows ? Array(entries.prefix(capacity - 1)) : entries

        for (index, line) in boardLines.enumerated() {
            if index < shown.count {
                line.text = "☕ " + Self.truncate(shown[index], limit: 22)
            } else if overflows && index == capacity - 1 {
                line.text = "+\(entries.count - shown.count)"
            } else {
                line.text = ""
            }
        }
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
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

    private func board(width: CGFloat, y: CGFloat) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: 12, y: y)
        node.zPosition = Self.furnitureZ - Self.carpetZ

        let boardWidth = width - 24
        let panel = SKShapeNode(rect: CGRect(x: 0, y: 0, width: boardWidth, height: Self.boardHeight),
                                cornerRadius: 3)
        panel.fillColor = Self.boardColor
        panel.strokeColor = Self.accentColor.withAlphaComponent(0.5)
        panel.lineWidth = 1.0
        node.addChild(panel)

        let titleBand = SKShapeNode(rect: CGRect(x: 0, y: Self.boardHeight - 14,
                                                 width: boardWidth, height: 14),
                                    cornerRadius: 3)
        titleBand.fillColor = Self.accentColor.withAlphaComponent(0.85)
        titleBand.strokeColor = .clear
        titleBand.zPosition = 1
        node.addChild(titleBand)

        let title = SKLabelNode(text: Localized.text("app.office.lounge.resting"))
        title.fontName = "Menlo-Bold"
        title.fontSize = 8
        title.fontColor = Self.boardColor
        title.horizontalAlignmentMode = .left
        title.verticalAlignmentMode = .center
        title.position = CGPoint(x: 7, y: Self.boardHeight - 7)
        title.zPosition = 2
        node.addChild(title)

        for (index, line) in boardLines.enumerated() {
            line.position = CGPoint(x: 8, y: Self.boardHeight - 30 - CGFloat(index) * 16)
            line.zPosition = 2
            node.addChild(line)
        }

        return node
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
