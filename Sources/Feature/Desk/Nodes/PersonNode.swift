import AppKit
import Foundation
import SpriteKit

/// 作業者の種類。
/// 人間（リポジトリ担当者）とエージェント（AIセッション作業員）で外見を差別化し、
/// 誰が人間で誰が自律エージェントかを一目で把握できるようにする。
enum PersonKind: Equatable {
    case human // リポジトリ担当の人間。髪・目・服（シャツ襟）を持つ
    case agent // セッション作業員（AI）。バイザー・サイバー調の筐体を持つ
}

/// オフィスで働くエージェント・作業員の SpriteKit ノード。
///
/// 俯瞰視点のため背丈を少し詰め、頭を大きめにして視認性を高めている。
/// 作業の仕草（タイピング・読書／検索・ターミナル注視・思考）や歩行アニメーションをカプセル化する。
final class PersonNode: SKNode {
    // MARK: - カラー定義

    /// 人間の肌色（ライト／ダーク両対応）
    static let humanSkinColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.95, green: 0.81, blue: 0.70, alpha: 0.98)
            : NSColor(red: 0.92, green: 0.78, blue: 0.67, alpha: 1.0)
    }

    /// 人間の髪色
    static let humanHairColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.16, green: 0.14, blue: 0.18, alpha: 1.0)
            : NSColor(red: 0.20, green: 0.18, blue: 0.22, alpha: 1.0)
    }

    /// 人間の服の色（開発者らしい落ち着いたセーター）
    static let humanClothesColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.26, green: 0.44, blue: 0.64, alpha: 0.98)
            : NSColor(red: 0.22, green: 0.40, blue: 0.60, alpha: 1.0)
    }

    /// 人間の目の色（見下ろし視点になじむ控えめなチャコール）
    static let humanEyeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.15, green: 0.13, blue: 0.16, alpha: 0.90)
            : NSColor(red: 0.18, green: 0.16, blue: 0.20, alpha: 0.90)
    }

    /// 人間のシャツ襟色（セーターの下から覗く白い襟）
    static let humanCollarColor = NSColor.white.withAlphaComponent(0.92)

    /// エージェントの筐体色（クールなチタン／スレート調）
    static let agentChassisColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.25, green: 0.30, blue: 0.38, alpha: 0.98)
            : NSColor(red: 0.36, green: 0.40, blue: 0.47, alpha: 1.0)
    }

    /// エージェントの輪郭線色（暗い部屋やモニタ前でも筐体をくっきり際立たせる白線）
    static let agentStrokeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.80)
            : NSColor.white.withAlphaComponent(0.95)
    }

    /// エージェントのバイザースリット発光色（シアン）
    static let agentVisorColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.20, green: 0.88, blue: 1.0, alpha: 0.98)
            : NSColor(red: 0.05, green: 0.72, blue: 0.95, alpha: 1.0)
    }

    /// エージェントのバイザー光沢
    static let agentVisorGlintColor = NSColor.white.withAlphaComponent(0.88)

    /// エージェントの胸部コアLED色
    static let agentCoreLedColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.20, green: 0.88, blue: 1.0, alpha: 0.90)
            : NSColor(red: 0.05, green: 0.70, blue: 0.95, alpha: 0.95)
    }

    // MARK: - プロパティ

    let kind: PersonKind
    let body: SKShapeNode
    let head: SKShapeNode
    let shadow: SKShapeNode
    /// 飛行中に足元から出るロケットの噴射炎。止まっている間は隠しておく
    let thruster: SKNode

    init(kind: PersonKind = .agent, tint: NSColor = .labelColor) {
        self.kind = kind

        body = SKShapeNode(rect: CGRect(x: -7, y: 0, width: 14, height: 18),
                           cornerRadius: 6)
        body.strokeColor = .clear

        head = SKShapeNode(circleOfRadius: 7)
        head.strokeColor = .clear
        head.position = CGPoint(x: 0, y: 21)
        head.zPosition = 5 // 体より前面に頭部を配置して襟や輪郭の重なりを綺麗に見せる

        shadow = SKShapeNode(ellipseOf: CGSize(width: 19, height: 7))
        shadow.fillColor = .black.withAlphaComponent(0.14)
        shadow.strokeColor = .clear
        shadow.zPosition = -1

        // 影（-1）より前、体（0）より後ろに置く。足元から噴いているように見せるため
        thruster = Self.createThrusterNode()
        thruster.position = CGPoint(x: 0, y: -1)
        thruster.zPosition = -0.5
        thruster.isHidden = true

        super.init()

        addChild(body)
        addChild(head)
        addChild(shadow)
        addChild(thruster)

        switch kind {
        case .human:
            // 人間：セーター、白いシャツ襟、肌色の顔、髪型、目元を配置する
            body.fillColor = Self.humanClothesColor

            let collar = SKShapeNode()
            let collarPath = CGMutablePath()
            collarPath.move(to: CGPoint(x: -3.0, y: 15.0))
            collarPath.addLine(to: CGPoint(x: 0, y: 12.0))
            collarPath.addLine(to: CGPoint(x: 3.0, y: 15.0))
            collar.path = collarPath
            collar.strokeColor = Self.humanCollarColor
            collar.lineWidth = 1.3
            collar.lineCap = .round
            collar.fillColor = .clear
            collar.zPosition = 1
            body.addChild(collar)

            head.fillColor = Self.humanSkinColor

            // 髪の毛（頭部上部を覆い、前髪の分け目を作る）
            let hair = SKShapeNode()
            let hairPath = CGMutablePath()
            hairPath.move(to: CGPoint(x: -7.2, y: -1.5))
            hairPath.addLine(to: CGPoint(x: -7.2, y: 0))
            hairPath.addArc(center: .zero, radius: 7.2, startAngle: .pi, endAngle: 0, clockwise: true)
            hairPath.addLine(to: CGPoint(x: 7.2, y: -1.5))
            hairPath.addQuadCurve(to: CGPoint(x: 0.0, y: 2.2), control: CGPoint(x: 3.5, y: -0.2))
            hairPath.addQuadCurve(to: CGPoint(x: -7.2, y: -1.5), control: CGPoint(x: -3.5, y: -0.5))
            hairPath.closeSubpath()
            hair.path = hairPath
            hair.fillColor = Self.humanHairColor
            hair.strokeColor = .clear
            hair.zPosition = 2
            head.addChild(hair)

            // 目元（見下ろし視点に合わせた控えめな瞳）
            let eyeL = SKShapeNode(circleOfRadius: 0.8)
            eyeL.position = CGPoint(x: -2.6, y: -2.0)
            eyeL.fillColor = Self.humanEyeColor
            eyeL.strokeColor = .clear
            eyeL.zPosition = 1
            head.addChild(eyeL)

            let eyeR = SKShapeNode(circleOfRadius: 0.8)
            eyeR.position = CGPoint(x: 2.6, y: -2.0)
            eyeR.fillColor = Self.humanEyeColor
            eyeR.strokeColor = .clear
            eyeR.zPosition = 1
            head.addChild(eyeR)

        case .agent:
            // エージェント：サイバー調のチタン筐体、白い輪郭線、発光バイザー、胸部コアLED
            let chassisFill = (tint == .labelColor) ? Self.agentChassisColor : tint.withAlphaComponent(0.85)
            body.fillColor = chassisFill
            body.strokeColor = Self.agentStrokeColor
            body.lineWidth = 1.0

            head.fillColor = (tint == .labelColor) ? Self.agentChassisColor : tint.withAlphaComponent(0.90)
            head.strokeColor = Self.agentStrokeColor
            head.lineWidth = 1.0

            // 発光バイザースリット
            let visor = SKShapeNode(rect: CGRect(x: -4.5, y: -2.2, width: 9.0, height: 2.4),
                                    cornerRadius: 1.2)
            visor.fillColor = Self.agentVisorColor
            visor.strokeColor = .clear
            visor.zPosition = 2
            head.addChild(visor)

            let visorGlint = SKShapeNode(rect: CGRect(x: -2.8, y: -1.4, width: 5.6, height: 0.8),
                                         cornerRadius: 0.4)
            visorGlint.fillColor = Self.agentVisorGlintColor
            visorGlint.strokeColor = .clear
            visorGlint.zPosition = 3
            head.addChild(visorGlint)

            // 胸部コアLED
            let coreLed = SKShapeNode(circleOfRadius: 1.0)
            coreLed.position = CGPoint(x: 0, y: 9.0)
            coreLed.fillColor = Self.agentCoreLedColor
            coreLed.strokeColor = .clear
            coreLed.zPosition = 1
            body.addChild(coreLed)
        }
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

    /// 足元から噴射して飛び立つ。
    ///
    /// 炎を出し、影を小さく薄くして床から浮いていることを見せる。
    /// 上下動は歩行のボブより周期を長く振れ幅を大きくしてあり、
    /// 同じ画面に歩く人と飛ぶエージェントが混ざっても区別が付く
    func startHovering() {
        shadow.removeAction(forKey: "lift")
        shadow.run(.group([
            .scale(to: 0.55, duration: 0.18),
            .fadeAlpha(to: 0.45, duration: 0.18)
        ]), withKey: "lift")

        igniteThruster()

        if action(forKey: "bob") != nil { return }
        run(.repeatForever(.sequence([
            .moveBy(x: 0, y: 2.2, duration: 0.42),
            .moveBy(x: 0, y: -2.2, duration: 0.42),
        ])), withKey: "bob")
    }

    /// 上下動を止めて着地する。
    ///
    /// 炎と影を戻すのをここでまとめてやっているのは、歩き終わりも飛び終わりも
    /// 呼ばれるのがこのメソッドだから。飛んだまま炎が出たり影が縮んだままになるのを防ぐ
    func stopBobbing() {
        removeAction(forKey: "bob")
        shadow.removeAction(forKey: "lift")
        shadow.run(.group([
            .scale(to: 1.0, duration: 0.18),
            .fadeAlpha(to: 1.0, duration: 0.18)
        ]), withKey: "lift")
        cutThruster()
    }

    /// 点火。ドンと吹き上がってから、ゆらぎの繰り返しに移る
    private func igniteThruster() {
        guard thruster.isHidden || thruster.action(forKey: "flicker") == nil else { return }

        thruster.removeAllActions()
        thruster.isHidden = false
        thruster.alpha = 1
        thruster.setScale(0.25)

        thruster.run(.sequence([
            .scale(to: 1.25, duration: 0.10),
            .scale(to: 1.0, duration: 0.08),
            .run { [weak self] in self?.flickerThruster() }
        ]), withKey: "launch")
    }

    /// 炎のゆらぎ。縦に伸び縮みさせて燃えているように見せる
    private func flickerThruster() {
        thruster.run(.repeatForever(.sequence([
            .group([.scaleY(to: 0.78, duration: 0.07), .fadeAlpha(to: 0.82, duration: 0.07)]),
            .group([.scaleY(to: 1.16, duration: 0.09), .fadeAlpha(to: 1.0, duration: 0.09)])
        ])), withKey: "flicker")
    }

    /// 消火。すぼめて消す
    private func cutThruster() {
        guard !thruster.isHidden else { return }
        thruster.removeAllActions()
        thruster.run(.sequence([
            .group([.scale(to: 0.1, duration: 0.14), .fadeOut(withDuration: 0.14)]),
            .hide()
        ]))
    }

    // MARK: - 噴射炎

    /// 下向きに伸びる噴射炎。外炎・内炎・ノズルの3枚で描く
    private static func createThrusterNode() -> SKNode {
        let node = SKNode()
        node.name = "thruster"

        let outer = SKShapeNode(path: flamePath(width: 10, length: 18))
        outer.fillColor = NSColor(red: 1.0, green: 0.44, blue: 0.10, alpha: 0.92)
        outer.strokeColor = .clear
        node.addChild(outer)

        let inner = SKShapeNode(path: flamePath(width: 5, length: 11))
        inner.fillColor = NSColor(red: 1.0, green: 0.90, blue: 0.48, alpha: 0.96)
        inner.strokeColor = .clear
        inner.zPosition = 1
        node.addChild(inner)

        // 噴射口。炎の根元を締めて、体から直接火が出ているように見えるのを防ぐ
        let nozzle = SKShapeNode(rect: CGRect(x: -4.5, y: -2, width: 9, height: 3.5), cornerRadius: 1.4)
        nozzle.fillColor = NSColor(white: 0.38, alpha: 1.0)
        nozzle.strokeColor = NSColor(white: 0.62, alpha: 0.9)
        nozzle.lineWidth = 0.6
        nozzle.zPosition = 2
        node.addChild(nozzle)

        return node
    }

    /// 根元の幅が `width`、原点から下へ `length` 伸びる炎の形
    private static func flamePath(width: CGFloat, length: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -width / 2, y: 0))
        path.addQuadCurve(to: CGPoint(x: 0, y: -length),
                          control: CGPoint(x: -width / 2, y: -length * 0.55))
        path.addQuadCurve(to: CGPoint(x: width / 2, y: 0),
                          control: CGPoint(x: width / 2, y: -length * 0.55))
        path.closeSubpath()
        return path
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
