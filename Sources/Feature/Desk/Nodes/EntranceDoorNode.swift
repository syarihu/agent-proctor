import AppKit
import Foundation
import SpriteKit

/// 正面エントランスの扉ノード（両開きドア、上部に緑の誘導灯、手前に玄関マット）。
///
/// エージェントの入退室に合わせて左右の扉がスムーズにスイング開閉する。
final class EntranceDoorNode: SKNode {
    let mat: SKShapeNode
    let frameNode: SKShapeNode
    let opening: SKShapeNode
    let leftLeafWrapper: SKNode
    let rightLeafWrapper: SKNode
    let exitSign: SKShapeNode

    // MARK: - カラーパレット

    static let doorFrameColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.28, alpha: 0.95)
            : NSColor(white: 0.68, alpha: 0.95)
    }

    static let doorOpeningColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.92, green: 0.85, blue: 0.65, alpha: 0.35)
            : NSColor(red: 0.98, green: 0.94, blue: 0.82, alpha: 0.90)
    }

    static let doorLeafColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 0.95)
            : NSColor(white: 0.92, alpha: 0.98)
    }

    static let doorMatColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 0.60)
            : NSColor(white: 0.82, alpha: 0.70)
    }

    // MARK: - 初期化

    init(wallHeight: CGFloat = 80) {
        // 壁が高くなったことで作業員（身長約30pt）に対してドアが詰まって見えないよう、
        // 開口部や扉の高さを自然な2倍強のプロポーションに拡張する
        let openingH = wallHeight - 16

        // 玄関マット（床の上）：出入りする作業員の足元をカバーするため幅を少し広げる
        mat = SKShapeNode(rect: CGRect(x: -28, y: -14, width: 56, height: 16), cornerRadius: 2.5)
        mat.fillColor = Self.doorMatColor
        mat.strokeColor = .secondaryLabelColor.withAlphaComponent(0.20)
        mat.lineWidth = 0.8
        mat.zPosition = -9980

        // ドア枠（壁に埋め込まれた外枠）：壁の全高（80pt）に合わせて重厚な枠を形成する
        frameNode = SKShapeNode(rect: CGRect(x: -25, y: 0, width: 50, height: wallHeight), cornerRadius: 2.0)
        frameNode.fillColor = Self.doorFrameColor
        frameNode.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        frameNode.lineWidth = 1.0
        frameNode.zPosition = -9970

        // 扉の奥（開いた時に見える廊下のあかり）
        opening = SKShapeNode(rect: CGRect(x: -22, y: 0, width: 44, height: openingH))
        opening.fillColor = Self.doorOpeningColor
        opening.strokeColor = .clear
        opening.zPosition = -9965

        // 左扉（開閉時に左端を軸にスケール変化）
        leftLeafWrapper = SKNode()
        leftLeafWrapper.name = "leftLeaf"
        leftLeafWrapper.position = CGPoint(x: -22, y: 0)
        leftLeafWrapper.zPosition = -9950

        let leftLeaf = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 21.5, height: openingH), cornerRadius: 1.2)
        leftLeaf.fillColor = Self.doorLeafColor
        leftLeaf.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        leftLeaf.lineWidth = 0.8
        leftLeafWrapper.addChild(leftLeaf)

        // 左ドアノブ（真鍮風の丸）
        let leftKnob = SKShapeNode(circleOfRadius: 1.4)
        leftKnob.fillColor = NSColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 0.9)
        leftKnob.strokeColor = .clear
        leftKnob.position = CGPoint(x: 18.0, y: openingH / 2)
        leftLeafWrapper.addChild(leftKnob)

        // 右扉（開閉時に右端を軸にスケール変化）
        rightLeafWrapper = SKNode()
        rightLeafWrapper.name = "rightLeaf"
        rightLeafWrapper.position = CGPoint(x: 22, y: 0)
        rightLeafWrapper.zPosition = -9950

        let rightLeaf = SKShapeNode(rect: CGRect(x: -21.5, y: 0, width: 21.5, height: openingH), cornerRadius: 1.2)
        rightLeaf.fillColor = Self.doorLeafColor
        rightLeaf.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        rightLeaf.lineWidth = 0.8
        rightLeafWrapper.addChild(rightLeaf)

        // 右ドアノブ
        let rightKnob = SKShapeNode(circleOfRadius: 1.4)
        rightKnob.fillColor = NSColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 0.9)
        rightKnob.strokeColor = .clear
        rightKnob.position = CGPoint(x: -18.0, y: openingH / 2)
        rightLeafWrapper.addChild(rightKnob)

        // 誘導灯（ドア上部の欄間に掲げる緑の非常口ランプ）
        exitSign = SKShapeNode(rect: CGRect(x: -13, y: wallHeight - 12, width: 26, height: 8), cornerRadius: 1.5)
        exitSign.fillColor = NSColor(red: 0.15, green: 0.82, blue: 0.40, alpha: 0.92)
        exitSign.strokeColor = .white.withAlphaComponent(0.6)
        exitSign.lineWidth = 0.6
        exitSign.zPosition = -9940

        let exitLabel = SKLabelNode(fontNamed: "Menlo-Bold")
        exitLabel.fontSize = 5.2
        exitLabel.fontColor = .white
        exitLabel.text = "EXIT"
        exitLabel.horizontalAlignmentMode = .center
        exitLabel.verticalAlignmentMode = .center
        exitLabel.position = CGPoint(x: 0, y: wallHeight - 8)
        exitLabel.zPosition = -9939
        exitSign.addChild(exitLabel)

        super.init()
        name = "entranceDoor"

        addChild(mat)
        addChild(frameNode)
        addChild(opening)
        addChild(leftLeafWrapper)
        addChild(rightLeafWrapper)
        addChild(exitSign)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 開閉アニメーション

    /// 扉を両開きで開閉する
    func animate(open: Bool, duration: TimeInterval = 0.22) {
        let targetScale: CGFloat = open ? 0.12 : 1.0
        let leftAction = SKAction.scaleX(to: targetScale, duration: duration)
        let rightAction = SKAction.scaleX(to: targetScale, duration: duration)
        leftAction.timingMode = open ? .easeOut : .easeIn
        rightAction.timingMode = open ? .easeOut : .easeIn
        leftLeafWrapper.run(leftAction, withKey: "doorSwing")
        rightLeafWrapper.run(rightAction, withKey: "doorSwing")
    }
}
