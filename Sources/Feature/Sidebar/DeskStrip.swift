import SpriteKit
import SwiftUI

/// サイドバー下部に置く作業場の帯。**素振り (spike) であって完成品ではない。**
///
/// 確かめたいのは1つだけ——280pt 幅の帯で、横視点の事務所が「読める」かどうか。
/// 台帳とは繋がっておらず、動いているのは作り物のタイマーである。
///
/// 見下ろし視点ではなく横視点にしているのは、帯の形が横長だから。
/// 見下ろしだと机を並べた時点で人の歩く床が無くなるが、横視点なら床は1本で済む。
/// 部屋をビューポートより広く作り、カメラで出来事のある所へ寄せることで、
/// サイドバーを広げたときに「絵が拡大する」のではなく「部屋が広く見える」ようにする。
struct DeskStrip: View {
    let height: CGFloat

    /// SwiftUI の再描画のたびにシーンが作り直されると、歩いている途中の人が
    /// 毎回入口に戻ってしまう。参照を1つ持ち続けるために箱に入れる
    @StateObject private var box = SceneBox()

    var body: some View {
        SpriteView(scene: box.scene, options: [.allowsTransparency])
            .frame(height: height)
            // 帯であることを示す上端の境界線。AttentionInbox の区切りと同じ濃さ
            .overlay(alignment: .top) {
                Rectangle().fill(Color.gray.opacity(0.2)).frame(height: 1)
            }
    }
}

private final class SceneBox: ObservableObject {
    /// 初期サイズは仮。`scaleMode = .resizeFill` なので実際の帯の大きさに合わせ直される
    let scene: DeskScene = {
        let scene = DeskScene(size: CGSize(width: 280, height: 150))
        scene.scaleMode = .resizeFill
        // NSVisualEffectView の上に載るので、地を塗ると背景のぼかしを塗り潰してしまう
        scene.backgroundColor = .clear
        return scene
    }()
}

/// 横視点の事務所。
final class DeskScene: SKScene {
    /// 部屋の幅。ビューポート (サイドバー幅) より広く取り、カメラで見る所を選ぶ
    private let roomWidth: CGFloat = 760
    /// 床の高さ。机も人もここを基準に積む
    private let floorY: CGFloat = 26

    /// 机の立ち位置。左端が hub、右が worker という想定
    private let deskX: [CGFloat] = [110, 380, 650]

    /// SKScene の `camera` に差すノード。出来事のある所へ寄せるために動かす
    private let eye = SKCameraNode()
    private var actor: SKNode?
    /// `didMove` は再入する場合があるので、組み立ては一度だけにする
    private var built = false

    override func didMove(to view: SKView) {
        guard !built else { return }
        built = true

        addChild(eye)
        camera = eye
        buildRoom()
        buildActor()
        startRound()
    }

    /// 帯の高さが変わってもカメラの上下位置と横の可動範囲を追従させる
    override func didChangeSize(_ oldSize: CGSize) {
        eye.position.y = size.height / 2
        eye.position.x = clampCameraX(eye.position.x)
    }

    // MARK: - 組み立て

    private func buildRoom() {
        let line = SKShapeNode(rectOf: CGSize(width: roomWidth, height: 1))
        line.fillColor = .secondaryLabelColor.withAlphaComponent(0.35)
        line.strokeColor = .clear
        line.position = CGPoint(x: roomWidth / 2, y: floorY)
        addChild(line)

        let names = ["hub", "worker-1", "worker-2"]
        for (index, x) in deskX.enumerated() {
            addChild(desk(at: x, label: names[index], isHub: index == 0))
        }
    }

    /// 机1つ。天板と脚、その上の画面。
    /// hub だけ画面の色を変えて、渡す側と渡される側を見分けられるようにする
    private func desk(at x: CGFloat, label: String, isHub: Bool) -> SKNode {
        let node = SKNode()
        node.position = CGPoint(x: x, y: floorY)

        let topWidth: CGFloat = 64
        let topY: CGFloat = 34

        let slab = SKShapeNode(rectOf: CGSize(width: topWidth, height: 5), cornerRadius: 2)
        slab.fillColor = .secondaryLabelColor.withAlphaComponent(0.5)
        slab.strokeColor = .clear
        slab.position = CGPoint(x: 0, y: topY)
        node.addChild(slab)

        for side in [-1.0, 1.0] as [CGFloat] {
            let leg = SKShapeNode(rectOf: CGSize(width: 3, height: topY))
            leg.fillColor = .secondaryLabelColor.withAlphaComponent(0.3)
            leg.strokeColor = .clear
            leg.position = CGPoint(x: side * (topWidth / 2 - 5), y: topY / 2)
            node.addChild(leg)
        }

        let screen = SKShapeNode(rectOf: CGSize(width: 26, height: 19), cornerRadius: 2)
        // 色は Palette と同じ値。素振りの間だけここに直書きしている
        screen.fillColor = isHub
            ? NSColor(red: 0.671, green: 0.533, blue: 0.941, alpha: 0.75)   // #ab88f0
            : NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.75)   // #4fc3f7
        screen.strokeColor = .clear
        screen.position = CGPoint(x: 0, y: topY + 12)
        node.addChild(screen)

        let caption = SKLabelNode(text: label)
        caption.fontName = "SFMono-Regular"
        caption.fontSize = 9
        caption.fontColor = .secondaryLabelColor.withAlphaComponent(0.65)
        caption.verticalAlignmentMode = .bottom
        caption.position = CGPoint(x: 0, y: topY + 26)
        node.addChild(caption)

        return node
    }

    /// 歩く人。頭・胴・脚だけの棒人間で、持ち物 (書類) を右手側に足せるようにしておく
    private func buildActor() {
        let node = SKNode()
        node.position = CGPoint(x: deskX[0], y: floorY)

        let body = SKShapeNode(rectOf: CGSize(width: 9, height: 16), cornerRadius: 4)
        body.fillColor = .labelColor.withAlphaComponent(0.75)
        body.strokeColor = .clear
        body.position = CGPoint(x: 0, y: 16)
        node.addChild(body)

        let head = SKShapeNode(circleOfRadius: 5.5)
        head.fillColor = .labelColor.withAlphaComponent(0.8)
        head.strokeColor = .clear
        head.position = CGPoint(x: 0, y: 29)
        node.addChild(head)

        for side in [-1.0, 1.0] as [CGFloat] {
            let leg = SKShapeNode(rectOf: CGSize(width: 3, height: 9), cornerRadius: 1.5)
            leg.fillColor = .labelColor.withAlphaComponent(0.6)
            leg.strokeColor = .clear
            leg.position = CGPoint(x: side * 2.5, y: 4.5)
            node.addChild(leg)
        }

        addChild(node)
        actor = node
    }

    // MARK: - 動き

    /// 書類を持って隣の机まで歩き、渡して戻る、を延々と繰り返す。
    /// 本番ではここが台帳やadjutantの受け渡しイベントに置き換わる
    private func startRound() {
        guard let actor else { return }

        let hub = deskX[0]
        let worker = deskX[1]

        let carry = SKAction.run { [weak self] in self?.givePaper(to: actor) }
        let drop = SKAction.run { [weak self] in self?.takePaper(from: actor) }

        let round = SKAction.sequence([
            .wait(forDuration: 0.8),
            carry,
            walk(actor, to: worker),
            .wait(forDuration: 0.6),
            drop,
            walk(actor, to: hub),
            .wait(forDuration: 1.2),
        ])
        actor.run(.repeatForever(round))
    }

    /// 歩行。距離に比例した時間をかけ、上下に小さく跳ねさせて歩いているように見せる。
    /// 同時にカメラを同じ時間で追従させる (出来事のある所を映す、の素振り)
    private func walk(_ node: SKNode, to x: CGFloat) -> SKAction {
        SKAction.run { [weak self] in
            guard let self else { return }
            let distance = abs(node.position.x - x)
            let duration = TimeInterval(distance / 60)

            let bob = SKAction.repeat(
                .sequence([
                    .moveBy(x: 0, y: 1.5, duration: 0.12),
                    .moveBy(x: 0, y: -1.5, duration: 0.12),
                ]),
                count: max(1, Int(duration / 0.24)))
            node.run(.group([.moveTo(x: x, duration: duration), bob]))

            self.eye.run(
                .moveTo(x: self.clampCameraX(x), duration: duration))
        }
    }

    private func givePaper(to node: SKNode) {
        let paper = SKShapeNode(rectOf: CGSize(width: 7, height: 9), cornerRadius: 1)
        paper.fillColor = NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.9)  // #ffa726
        paper.strokeColor = .clear
        paper.position = CGPoint(x: 7, y: 15)
        paper.name = "paper"
        node.addChild(paper)
    }

    private func takePaper(from node: SKNode) {
        guard let paper = node.childNode(withName: "paper") else { return }
        // 机に置かれて消える、ところまでを1つの所作として見せる
        paper.run(.sequence([
            .group([.moveBy(x: 12, y: 18, duration: 0.3), .fadeOut(withDuration: 0.3)]),
            .removeFromParent(),
        ]))
    }

    /// カメラが部屋の外を映さないように可動範囲を切る。
    /// ビューポートが部屋より広いときは寄せようがないので、部屋の中央に置く
    private func clampCameraX(_ x: CGFloat) -> CGFloat {
        let half = size.width / 2
        guard roomWidth > size.width else { return roomWidth / 2 }
        return min(max(x, half), roomWidth - half)
    }
}
