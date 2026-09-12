import AppKit
import Foundation
import SpriteKit

/// オフィスで働くエージェント・作業員の SpriteKit ノード。
///
/// 俯瞰視点のため背丈を少し詰め、頭を大きめにして視認性を高めている。
/// 作業の仕草（タイピング・読書／検索・ターミナル注視・思考）や歩行アニメーションをカプセル化する。
final class PersonNode: SKNode {
    let body: SKShapeNode
    let head: SKShapeNode
    let shadow: SKShapeNode

    init(tint: NSColor) {
        body = SKShapeNode(rect: CGRect(x: -7, y: 0, width: 14, height: 18),
                           cornerRadius: 6)
        body.fillColor = tint.withAlphaComponent(0.75)
        body.strokeColor = .clear

        head = SKShapeNode(circleOfRadius: 7)
        head.fillColor = tint.withAlphaComponent(0.85)
        head.strokeColor = .clear
        head.position = CGPoint(x: 0, y: 21)

        shadow = SKShapeNode(ellipseOf: CGSize(width: 19, height: 7))
        shadow.fillColor = .black.withAlphaComponent(0.14)
        shadow.strokeColor = .clear
        shadow.zPosition = -1

        super.init()

        addChild(body)
        addChild(head)
        addChild(shadow)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - アニメーション

    /// 歩行時の上下ボブ運動を開始する
    func startBobbing() {
        if action(forKey: "bob") != nil { return }
        let bobAction = SKAction.repeatForever(.sequence([
            .moveBy(x: 0, y: 1.2, duration: 0.12),
            .moveBy(x: 0, y: -1.2, duration: 0.12),
        ]))
        run(bobAction, withKey: "bob")
    }

    /// 歩行時の上下ボブ運動を停止する
    func stopBobbing() {
        removeAction(forKey: "bob")
    }

    /// 着席時などの嬉しいリアクション（ピョンと少し跳ねるスケール変化）
    func cheer() {
        run(.sequence([
            .scale(to: 1.38, duration: 0.12),
            .scale(to: 1.2, duration: 0.12),
        ]))
    }

    /// 仕草（ジェスチャー）を初期状態に戻す
    func resetGesture() {
        removeAction(forKey: "gesture")
        zRotation = 0
        childNode(withName: "loupe")?.removeFromParent()
        childNode(withName: "sheet")?.removeFromParent()
    }

    /// ツールに応じた仕草（タイピング、読書、ターミナル、思考）を付ける
    func applyGesture(_ gesture: DeskGesture, isHelper: Bool) {
        let currentGesture = userData?["gesture"] as? String
        let nextSignature = "\(gesture)"
        if currentGesture == nextSignature { return }
        if userData == nil { userData = NSMutableDictionary() }
        userData?["gesture"] = nextSignature

        removeAction(forKey: "gesture")
        zRotation = 0

        let scale: CGFloat = isHelper ? 0.94 : 1.2
        let motion: SKAction
        switch gesture {
        case .typing:
            motion = .sequence([
                .moveBy(x: 0, y: 1.2, duration: 0.28),
                .moveBy(x: 0, y: -1.2, duration: 0.28),
            ])
        case .reading:
            // 覗き込みながらキョロキョロ見比べる。
            // 身を乗り出して左右に首を傾げることで、画面や書類を熱心に探している姿にする
            motion = .sequence([
                .group([
                    .moveBy(x: 0, y: -1.6, duration: 0.35),
                    .rotate(toAngle: 0.12, duration: 0.35),
                ]),
                .wait(forDuration: 0.20),
                .rotate(toAngle: -0.12, duration: 0.45),
                .wait(forDuration: 0.20),
                .group([
                    .moveBy(x: 0, y: 1.6, duration: 0.35),
                    .rotate(toAngle: 0, duration: 0.35),
                ]),
                .wait(forDuration: 0.15),
            ])
        case .terminal:
            // 流れるのを見ている。時々うなずくだけ
            motion = .sequence([
                .wait(forDuration: 0.9),
                .moveBy(x: 0, y: -1.6, duration: 0.14),
                .moveBy(x: 0, y: 1.6, duration: 0.22),
            ])
        case .thinking:
            // 自分では手を動かしていない。呼吸だけ
            motion = .sequence([
                .scaleY(to: scale * 1.035, duration: 1.1),
                .scaleY(to: scale, duration: 1.1),
            ])
        }
        run(.repeatForever(motion), withKey: "gesture")

        // 調べる・探すときは手元に虫眼鏡（ルーペ）を持たせる
        let loupe = childNode(withName: "loupe") ?? childNode(withName: "sheet")
        if gesture == .reading {
            guard loupe == nil else { return }
            let tool = Self.createMagnifyingGlass()
            tool.name = "loupe"
            tool.position = CGPoint(x: 6, y: 6)
            tool.zPosition = 25
            addChild(tool)
            tool.run(.repeatForever(.sequence([
                .group([
                    .moveBy(x: -4.0, y: 1.5, duration: 0.45),
                    .rotate(toAngle: -0.28, duration: 0.45),
                ]),
                .wait(forDuration: 0.15),
                .group([
                    .moveBy(x: 4.0, y: -1.5, duration: 0.45),
                    .rotate(toAngle: 0.22, duration: 0.45),
                ]),
                .wait(forDuration: 0.15),
            ])), withKey: "scan")
        } else {
            loupe?.removeFromParent()
        }
    }

    /// 調べる・探すときに手に持つ虫眼鏡（ルーペ）
    static func createMagnifyingGlass() -> SKNode {
        let loupe = SKNode()

        // 持ち手（柄）
        let handlePath = CGMutablePath()
        handlePath.move(to: CGPoint(x: 0, y: 0))
        handlePath.addLine(to: CGPoint(x: -3.8, y: 3.8))
        let handle = SKShapeNode(path: handlePath)
        handle.strokeColor = .labelColor.withAlphaComponent(0.9)
        handle.lineWidth = 1.8
        handle.lineCap = .round
        loupe.addChild(handle)

        // レンズ枠
        let rim = SKShapeNode(circleOfRadius: 4.5)
        rim.position = CGPoint(x: -6.8, y: 6.8)
        rim.strokeColor = .labelColor.withAlphaComponent(0.85)
        rim.lineWidth = 1.3
        rim.fillColor = NSColor(red: 0.55, green: 0.85, blue: 1.0, alpha: 0.40)
        loupe.addChild(rim)

        // レンズのガラス反射
        let glint = SKShapeNode(circleOfRadius: 0.9)
        glint.position = CGPoint(x: -8.2, y: 8.2)
        glint.fillColor = .white.withAlphaComponent(0.85)
        glint.strokeColor = .clear
        loupe.addChild(glint)

        return loupe
    }
}
