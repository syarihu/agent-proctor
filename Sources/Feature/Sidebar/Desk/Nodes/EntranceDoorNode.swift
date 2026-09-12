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

    init(wallHeight: CGFloat = 32) {
        // 玄関マット（床の上）
        mat = SKShapeNode(rect: CGRect(x: -24, y: -10, width: 48, height: 12), cornerRadius: 2.0)
        mat.fillColor = Self.doorMatColor
        mat.strokeColor = .secondaryLabelColor.withAlphaComponent(0.20)
        mat.lineWidth = 0.8
        mat.zPosition = -9980

        // ドア枠（壁に埋め込まれた外枠）
        frameNode = SKShapeNode(rect: CGRect(x: -21, y: 0, width: 42, height: wallHeight), cornerRadius: 1.5)
        frameNode.fillColor = Self.doorFrameColor
        frameNode.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        frameNode.lineWidth = 1.0
        frameNode.zPosition = -9970

        // 扉の奥（開いた時に見える廊下のあかり）
        opening = SKShapeNode(rect: CGRect(x: -19, y: 0, width: 38, height: wallHeight - 8))
        opening.fillColor = Self.doorOpeningColor
        opening.strokeColor = .clear
        opening.zPosition = -9965

        // 左扉（開閉時に左端を軸にスケール変化）
        leftLeafWrapper = SKNode()
        leftLeafWrapper.name = "leftLeaf"
        leftLeafWrapper.position = CGPoint(x: -19, y: 0)
        leftLeafWrapper.zPosition = -9950

        let leftLeaf = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 18.5, height: wallHeight - 8), cornerRadius: 1)
        leftLeaf.fillColor = Self.doorLeafColor
        leftLeaf.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        leftLeaf.lineWidth = 0.8
        leftLeafWrapper.addChild(leftLeaf)

        // 左ドアノブ（真鍮風の丸）
        let leftKnob = SKShapeNode(circleOfRadius: 1.1)
        leftKnob.fillColor = NSColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 0.9)
        leftKnob.strokeColor = .clear
        leftKnob.position = CGPoint(x: 15.5, y: (wallHeight - 8) / 2)
        leftLeafWrapper.addChild(leftKnob)

        // 右扉（開閉時に右端を軸にスケール変化）
        rightLeafWrapper = SKNode()
        rightLeafWrapper.name = "rightLeaf"
        rightLeafWrapper.position = CGPoint(x: 19, y: 0)
        rightLeafWrapper.zPosition = -9950

        let rightLeaf = SKShapeNode(rect: CGRect(x: -18.5, y: 0, width: 18.5, height: wallHeight - 8), cornerRadius: 1)
        rightLeaf.fillColor = Self.doorLeafColor
        rightLeaf.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        rightLeaf.lineWidth = 0.8
        rightLeafWrapper.addChild(rightLeaf)

        // 右ドアノブ
        let rightKnob = SKShapeNode(circleOfRadius: 1.1)
        rightKnob.fillColor = NSColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 0.9)
        rightKnob.strokeColor = .clear
        rightKnob.position = CGPoint(x: -15.5, y: (wallHeight - 8) / 2)
        rightLeafWrapper.addChild(rightKnob)

        // 誘導灯（ドア上部のかもいに掲げる緑のランプ）
        exitSign = SKShapeNode(rect: CGRect(x: -9, y: wallHeight - 7, width: 18, height: 5.5), cornerRadius: 1.2)
        exitSign.fillColor = NSColor(red: 0.15, green: 0.82, blue: 0.40, alpha: 0.92)
        exitSign.strokeColor = .white.withAlphaComponent(0.6)
        exitSign.lineWidth = 0.6
        exitSign.zPosition = -9940

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
