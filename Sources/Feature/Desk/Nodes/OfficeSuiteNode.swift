import AppKit
import Foundation
import SpriteKit

/// 組織1つ分の専用スイート（個室）。
///
/// 北壁に出入口、南奥壁に組織銘板を置く。扉から入ると正面奥に組織名が見える関係を
/// 組織が何個あっても保つため、上下で鏡写しにはしない。
/// 西壁には区画の行ごとに側面扉を開け、共用ラウンジへ最短で抜けられるようにする。
///
/// 床のカーペットは組織キーから引いた色で染める。組織が増えても衝突しにくいよう、
/// 名前のハッシュから色相を取り、彩度と明度だけを固定している
final class OfficeSuiteNode: SKNode {
    // MARK: - 重なり順

    /// 床（-10000）の上、机（-1500〜0 付近）の下に敷く
    static let carpetZ: CGFloat = -9800
    static let wallZ: CGFloat = -9760
    static let plateZ: CGFloat = -9740

    // MARK: - 色

    /// 組織キーから引く固有色。色相だけを名前から取り、彩度・明度は揃える
    static func tint(for key: String) -> NSColor {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = hash &* 33 &+ UInt64(byte)
        }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hue: hue, saturation: 0.52, brightness: 0.78, alpha: 1.0)
                : NSColor(hue: hue, saturation: 0.62, brightness: 0.55, alpha: 1.0)
        }
    }

    static let carpetColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1.0, alpha: 0.035)
            : NSColor(white: 0.0, alpha: 0.030)
    }

    static let wallColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.42, alpha: 0.85)
            : NSColor(white: 0.58, alpha: 0.85)
    }

    static let plateBandColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.17, green: 0.14, blue: 0.11, alpha: 0.95)
            : NSColor(red: 0.87, green: 0.83, blue: 0.77, alpha: 0.95)
    }

    static let plateFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 0.95)
            : NSColor(white: 1.0, alpha: 0.95)
    }

    // MARK: - 初期化

    /// - Parameters:
    ///   - suite: 間取りが決めたスイート1つ分
    ///   - showsWalls: 壁とカーペットを描くか。狭いサイドバーでは組織銘板だけにする
    ///   - showsSideDoors: 西壁に側面扉を開けるか。共用ラウンジを出すときだけ真
    init(suite: OfficeFloorPlan.Suite, showsWalls: Bool, showsSideDoors: Bool) {
        super.init()

        name = "suite:\(suite.orgKey)"
        position = suite.frame.origin
        zPosition = Self.carpetZ

        let width = suite.frame.width
        let height = suite.frame.height
        let accent = Self.tint(for: suite.orgKey)

        // 南奥壁の組織銘板は壁の有無に関わらず出す。組織の切れ目を示す唯一の目印になる
        addChild(plate(suite: suite, accent: accent))

        guard showsWalls else { return }

        addChild(carpet(width: width, height: height, accent: accent))

        // 壁は4辺を1本ずつ描き、扉のぶんだけ切り欠く。
        // 1枚の枠として描いてしまうと開口を作れない
        let doorHalf = OfficeMetrics.suiteDoorWidth / 2
        let doorCenter = suite.doorX - suite.frame.minX

        // 北壁（出入口あり）
        addWall(from: CGPoint(x: 0, y: height), to: CGPoint(x: doorCenter - doorHalf, y: height), accent: accent)
        addWall(from: CGPoint(x: doorCenter + doorHalf, y: height), to: CGPoint(x: width, y: height), accent: accent)
        addChild(doorway(center: CGPoint(x: doorCenter, y: height), length: OfficeMetrics.suiteDoorWidth,
                         isVertical: false, accent: accent))

        // 東壁
        addWall(from: CGPoint(x: width, y: 0), to: CGPoint(x: width, y: height), accent: accent)

        // 西壁（側面扉あり）。開口を下から順に切り抜いていく
        let openings: [ClosedRange<CGFloat>] = showsSideDoors
            ? suite.sideDoorYs
                .map { $0 - suite.frame.minY }
                .map { ($0 - OfficeMetrics.sideDoorHeight / 2)...($0 + OfficeMetrics.sideDoorHeight / 2) }
                .sorted { $0.lowerBound < $1.lowerBound }
            : []
        var cursor: CGFloat = 0
        for opening in openings {
            let low = max(0, min(height, opening.lowerBound))
            let high = max(0, min(height, opening.upperBound))
            guard high > low else { continue }
            if low > cursor {
                addWall(from: CGPoint(x: 0, y: cursor), to: CGPoint(x: 0, y: low), accent: accent)
            }
            addChild(doorway(center: CGPoint(x: 0, y: (low + high) / 2), length: high - low,
                             isVertical: true, accent: accent))
            cursor = high
        }
        if cursor < height {
            addWall(from: CGPoint(x: 0, y: cursor), to: CGPoint(x: 0, y: height), accent: accent)
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 部品

    private func carpet(width: CGFloat, height: CGFloat, accent: NSColor) -> SKNode {
        let node = SKNode()

        let base = SKShapeNode(rect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 7)
        base.fillColor = Self.carpetColor
        base.strokeColor = .clear
        base.zPosition = 0
        node.addChild(base)

        // 組織の色は縁だけに乗せる。床全面を染めると机やホワイトボードの白が沈む
        let edge = SKShapeNode(rect: CGRect(x: 0, y: 0, width: width, height: height), cornerRadius: 7)
        edge.fillColor = .clear
        edge.strokeColor = accent.withAlphaComponent(0.45)
        edge.lineWidth = 1.2
        edge.zPosition = 1
        node.addChild(edge)

        return node
    }

    private func addWall(from: CGPoint, to: CGPoint, accent: NSColor) {
        guard hypot(to.x - from.x, to.y - from.y) > 0.5 else { return }
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        let wall = SKShapeNode(path: path)
        wall.strokeColor = Self.wallColor
        wall.lineWidth = 3
        wall.lineCap = .round
        wall.zPosition = Self.wallZ - Self.carpetZ
        addChild(wall)
    }

    /// 扉の開口。壁を切り欠いた部分に敷居と方向の目印を置く
    private func doorway(center: CGPoint, length: CGFloat, isVertical: Bool, accent: NSColor) -> SKNode {
        let node = SKNode()
        node.position = center
        node.zPosition = Self.wallZ - Self.carpetZ

        let sill = SKShapeNode(rect: isVertical
            ? CGRect(x: -2, y: -length / 2, width: 4, height: length)
            : CGRect(x: -length / 2, y: -2, width: length, height: 4),
                               cornerRadius: 1.5)
        sill.fillColor = accent.withAlphaComponent(0.35)
        sill.strokeColor = accent.withAlphaComponent(0.6)
        sill.lineWidth = 0.8
        node.addChild(sill)

        // 開口の両端に立つ縦枠。扉があることが遠目にも分かる
        for side: CGFloat in [-1, 1] {
            let jamb = SKShapeNode(circleOfRadius: 2.4)
            jamb.position = isVertical
                ? CGPoint(x: 0, y: side * length / 2)
                : CGPoint(x: side * length / 2, y: 0)
            jamb.fillColor = Self.wallColor
            jamb.strokeColor = .clear
            node.addChild(jamb)
        }

        return node
    }

    /// 南奥壁の帯と、そこに掛かる組織銘板
    private func plate(suite: OfficeFloorPlan.Suite, accent: NSColor) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: 0, y: 0)
        node.zPosition = Self.plateZ - Self.carpetZ

        let bandHeight = suite.plateBand.height
        guard bandHeight > 0 else { return node }

        let band = SKShapeNode(rect: CGRect(x: 0, y: 0, width: suite.frame.width, height: bandHeight),
                               cornerRadius: 3)
        band.fillColor = Self.plateBandColor
        band.strokeColor = .clear
        node.addChild(band)

        let label = SKLabelNode(text: suite.orgName)
        label.fontName = "Menlo-Bold"
        label.fontSize = 11
        label.fontColor = accent
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .center

        let textWidth = max(48, label.frame.width)
        let plateWidth = textWidth + 26
        let plateRect = CGRect(x: 14, y: (bandHeight - 22) / 2, width: plateWidth, height: 22)
        let frame = SKShapeNode(rect: plateRect, cornerRadius: 3)
        frame.fillColor = Self.plateFillColor
        frame.strokeColor = accent.withAlphaComponent(0.8)
        frame.lineWidth = 1.2
        node.addChild(frame)

        label.position = CGPoint(x: plateRect.minX + 13, y: plateRect.midY)
        label.zPosition = 1
        node.addChild(label)

        return node
    }
}
