import AppKit
import Foundation
import SpriteKit

/// 同じ組織の中でリポジトリ区画を分ける観葉植物のプランター帯。
///
/// 壁で仕切ると同じ会社の中に壁が立つことになって重いので、
/// オフィス家具の定番であるプランターで柔らかくゾーニングする。
/// 見下ろし視点なので、上から見た「箱と、そこから覗く葉」として描く
final class OfficePlanterNode: SKNode {
    // MARK: - 重なり順

    /// スイートのカーペット（-9800）の上、机より下に置く
    static let planterZ: CGFloat = -9700

    // MARK: - 色

    static let boxColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.20, green: 0.21, blue: 0.23, alpha: 0.95)
            : NSColor(red: 0.78, green: 0.76, blue: 0.72, alpha: 0.95)
    }

    static let boxEdgeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.42, alpha: 0.9)
            : NSColor(white: 0.55, alpha: 0.9)
    }

    static let soilColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.13, green: 0.11, blue: 0.09, alpha: 1.0)
            : NSColor(red: 0.32, green: 0.26, blue: 0.20, alpha: 1.0)
    }

    static let leafColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.31, green: 0.70, blue: 0.40, alpha: 1.0)
            : NSColor(red: 0.22, green: 0.55, blue: 0.30, alpha: 1.0)
    }

    static let leafShadeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.20, green: 0.48, blue: 0.28, alpha: 1.0)
            : NSColor(red: 0.15, green: 0.38, blue: 0.21, alpha: 1.0)
    }

    // MARK: - 初期化

    /// 株ひとつ分の間隔。これより細かく置くと、遠目には緑の帯に潰れて植物に見えなくなる
    private static let plantPitch: CGFloat = 46

    init(planter: OfficeFloorPlan.Planter) {
        super.init()

        name = "planter"
        position = planter.frame.origin
        zPosition = Self.planterZ

        let size = planter.frame.size

        // 鉢の箱。角を丸めて、床に落ちる影を一段暗く敷く
        let shadow = SKShapeNode(rect: CGRect(x: 1.5, y: -2.5, width: size.width, height: size.height),
                                 cornerRadius: 4)
        shadow.fillColor = .black.withAlphaComponent(0.16)
        shadow.strokeColor = .clear
        shadow.zPosition = -1
        addChild(shadow)

        let box = SKShapeNode(rect: CGRect(origin: .zero, size: size), cornerRadius: 4)
        box.fillColor = Self.boxColor
        box.strokeColor = Self.boxEdgeColor
        box.lineWidth = 1.0
        addChild(box)

        let soilRect = CGRect(x: 3, y: 3, width: max(0, size.width - 6), height: max(0, size.height - 6))
        let soil = SKShapeNode(rect: soilRect, cornerRadius: 2.5)
        soil.fillColor = Self.soilColor
        soil.strokeColor = .clear
        soil.zPosition = 1
        addChild(soil)

        // 株を帯の長辺に沿って等間隔に植える
        let length = planter.isVertical ? size.height : size.width
        let count = max(1, Int((length / Self.plantPitch).rounded()))
        for index in 0..<count {
            let t = (CGFloat(index) + 0.5) / CGFloat(count)
            let center = planter.isVertical
                ? CGPoint(x: size.width / 2, y: length * t)
                : CGPoint(x: length * t, y: size.height / 2)
            addChild(plant(at: center, seed: index))
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 部品

    /// 上から見た株ひとつ。中心から放射状に葉を伸ばす
    private func plant(at center: CGPoint, seed: Int) -> SKNode {
        let node = SKNode()
        node.position = center
        node.zPosition = 2

        let leaves = 7
        // 株ごとに向きをずらす。全部同じ向きだと並べたときに模様に見えてしまう
        let offset = CGFloat(seed) * 0.7

        for index in 0..<leaves {
            let angle = offset + CGFloat(index) * (.pi * 2 / CGFloat(leaves))
            let length: CGFloat = index.isMultiple(of: 2) ? 11 : 8.5
            let leaf = SKShapeNode(path: Self.leafPath(length: length))
            leaf.fillColor = index.isMultiple(of: 2) ? Self.leafColor : Self.leafShadeColor
            leaf.strokeColor = .clear
            leaf.zRotation = angle
            node.addChild(leaf)
        }

        let core = SKShapeNode(circleOfRadius: 2.2)
        core.fillColor = Self.leafShadeColor
        core.strokeColor = .clear
        core.zPosition = 1
        node.addChild(core)

        return node
    }

    /// 根元から先端へ細くなる葉1枚。原点から +X 方向へ伸ばし、回転で向きを付ける
    private static func leafPath(length: CGFloat) -> CGPath {
        let width: CGFloat = 4.2
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addQuadCurve(to: CGPoint(x: length, y: 0),
                          control: CGPoint(x: length * 0.5, y: width))
        path.addQuadCurve(to: .zero,
                          control: CGPoint(x: length * 0.5, y: -width))
        path.closeSubpath()
        return path
    }
}
