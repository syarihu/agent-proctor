import SpriteKit
import SwiftUI

/// サイドバー下部に置く作業場の帯。**素振り (spike) であって完成品ではない。**
///
/// 確かめたいのは1つだけ——280pt の帯で、斜め上から見た事務所が「読める」かどうか。
/// 台帳とは繋がっておらず、動いているのは作り物のタイマーである。
///
/// 視点は 2D ゲームでよくある俯瞰 (見下ろしを少し斜めに倒したもの)。
/// 机に天板と前面の2枚を描くこと、手前のものほど後に描くこと、
/// 人が上下にも歩くこと、の3つで奥行きを出している。
/// 部屋は帯より横に広く、カメラで出来事のある所へ寄せる。
/// そのため、サイドバーを広げると絵が拡大するのではなく部屋が広く見える。
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

/// 斜め上から見た事務所。
final class DeskScene: SKScene {
    /// 部屋の幅。ビューポート (サイドバー幅) より広く取り、カメラで見る所を選ぶ
    private let roomWidth: CGFloat = 800

    /// 奥行きは帯の高さに収める。上下にもスクロールさせると目が休まらないので、
    /// 縦は「奥の列と手前の列」を置ける分だけあればよい
    private var backRowY: CGFloat { size.height * 0.63 }
    private var frontRowY: CGFloat { size.height * 0.26 }

    /// 部屋の中心。hub の机を置き、カメラの落ち着き先にもする
    private let centerX: CGFloat = 400

    /// 机の立ち位置。**hub を中心に worker が取り囲む**という想定。
    ///
    /// hub は奥の列の真ん中（部屋の上座）。worker は手前の列に4つ並べ、
    /// 残りを奥の列の両端に置いて、hub から見て左右対称になるようにしている。
    /// 中心から配ることで、カメラが片側へ寄りっぱなしにならず左右に振れる。
    ///
    /// 間隔は 120pt。机の幅が 58pt なので隣とは 62pt 空く。
    /// これ以上離すと 280pt のビューポートに机が1つ半しか入らず、事務所に見えない
    private var desks: [(x: CGFloat, y: CGFloat, name: String, isHub: Bool)] {
        [
            (centerX, backRowY, "hub", true),
            (centerX - 60, frontRowY, "worker-1", false),
            (centerX + 60, frontRowY, "worker-2", false),
            (centerX - 180, frontRowY, "worker-3", false),
            (centerX + 180, frontRowY, "worker-4", false),
            (centerX - 240, backRowY, "worker-5", false),
            (centerX + 240, backRowY, "worker-6", false),
        ]
    }

    /// SKScene の `camera` に差すノード。出来事のある所へ寄せるために動かす
    private let eye = SKCameraNode()
    private var walker: SKNode?
    /// 実寸が決まってから組み立てる。奥行きの位置を帯の高さから決めているため
    private var built = false

    override func didMove(to view: SKView) {
        addChild(eye)
        camera = eye
        buildIfPossible()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        eye.position.y = size.height / 2
        eye.position.x = clampCameraX(eye.position.x)
        buildIfPossible()
    }

    private func buildIfPossible() {
        guard !built, size.height > 40 else { return }
        built = true
        eye.position = CGPoint(x: clampCameraX(desks[0].x), y: size.height / 2)
        buildRoom()
        buildWalker()
        startRound()
    }

    // MARK: - 組み立て

    private func buildRoom() {
        let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: roomWidth, height: size.height))
        floor.fillColor = .secondaryLabelColor.withAlphaComponent(0.06)
        floor.strokeColor = .clear
        floor.zPosition = -10000
        addChild(floor)

        // 床のタイル目。地面がどこにあるかを示すためだけのものなので、うんと薄くする
        let tile: CGFloat = 44
        for x in stride(from: 0, through: roomWidth, by: tile) {
            addChild(hairline(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: size.height)))
        }
        for y in stride(from: 0, through: size.height, by: tile) {
            addChild(hairline(from: CGPoint(x: 0, y: y), to: CGPoint(x: roomWidth, y: y)))
        }

        // 奥の壁。上端に帯を置くと「奥がある」ことが一目で分かる
        let wallHeight = size.height * 0.12
        let wall = SKShapeNode(rect: CGRect(x: 0, y: size.height - wallHeight,
                                            width: roomWidth, height: wallHeight))
        wall.fillColor = .secondaryLabelColor.withAlphaComponent(0.12)
        wall.strokeColor = .clear
        wall.zPosition = -9990
        addChild(wall)

        for desk in desks {
            addChild(deskNode(at: CGPoint(x: desk.x, y: desk.y),
                              label: desk.name, isHub: desk.isHub))
        }

        // 席に着いたままの人。無人の事務所だと俯瞰しているのか分かりにくい。
        // 机の奥に置くので、重なり順 (-y) では机より後ろに回る
        for index in [3, 6] {
            let seated = person(tint: .secondaryLabelColor)
            seated.position = CGPoint(x: desks[index].x, y: desks[index].y + 20)
            seated.zPosition = -seated.position.y
            addChild(seated)
        }
    }

    private func hairline(from: CGPoint, to: CGPoint) -> SKShapeNode {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        let line = SKShapeNode(path: path)
        line.strokeColor = .secondaryLabelColor.withAlphaComponent(0.07)
        line.lineWidth = 1
        line.zPosition = -9999
        return line
    }

    /// 机1つ。天板 (明るい) と前面 (暗い) の2枚で厚みを出し、奥にモニタを置く。
    /// hub だけモニタの色を変えて、渡す側と渡される側を見分けられるようにする
    private func deskNode(at point: CGPoint, label: String, isHub: Bool) -> SKNode {
        let node = SKNode()
        node.position = point
        // 手前のものほど後に描く。人が机の前に立ったときに正しく重なる
        node.zPosition = -point.y

        let width: CGFloat = 58
        let depth: CGFloat = 17

        let front = SKShapeNode(rect: CGRect(x: -width / 2, y: -depth / 2 - 6,
                                             width: width, height: 7),
                                cornerRadius: 1.5)
        front.fillColor = .secondaryLabelColor.withAlphaComponent(0.32)
        front.strokeColor = .clear
        node.addChild(front)

        let top = SKShapeNode(rect: CGRect(x: -width / 2, y: -depth / 2,
                                           width: width, height: depth),
                              cornerRadius: 2.5)
        top.fillColor = .secondaryLabelColor.withAlphaComponent(0.5)
        top.strokeColor = .clear
        node.addChild(top)

        let screen = SKShapeNode(rect: CGRect(x: -11, y: depth / 2 - 4, width: 22, height: 14),
                                 cornerRadius: 2)
        // 色は Palette と同じ値。素振りの間だけここに直書きしている
        screen.fillColor = isHub
            ? NSColor(red: 0.671, green: 0.533, blue: 0.941, alpha: 0.8)   // #ab88f0
            : NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.8)   // #4fc3f7
        screen.strokeColor = .clear
        node.addChild(screen)

        let caption = SKLabelNode(text: label)
        caption.fontName = "SFMono-Regular"
        caption.fontSize = 8
        caption.fontColor = .secondaryLabelColor.withAlphaComponent(0.7)
        caption.verticalAlignmentMode = .bottom
        caption.position = CGPoint(x: 0, y: depth / 2 + 12)
        node.addChild(caption)

        return node
    }

    /// 人1人。俯瞰なので背丈は詰めて、頭を大きめに取る
    private func person(tint: NSColor) -> SKNode {
        let node = SKNode()

        let body = SKShapeNode(rect: CGRect(x: -5, y: 0, width: 10, height: 12),
                               cornerRadius: 4)
        body.fillColor = tint.withAlphaComponent(0.75)
        body.strokeColor = .clear
        node.addChild(body)

        let head = SKShapeNode(circleOfRadius: 5)
        head.fillColor = tint.withAlphaComponent(0.85)
        head.strokeColor = .clear
        head.position = CGPoint(x: 0, y: 15)
        node.addChild(head)

        // 足元の影。地面に立っていることを示す
        let shadow = SKShapeNode(ellipseOf: CGSize(width: 13, height: 5))
        shadow.fillColor = .black.withAlphaComponent(0.14)
        shadow.strokeColor = .clear
        shadow.position = CGPoint(x: 0, y: 0)
        shadow.zPosition = -1
        node.addChild(shadow)

        return node
    }

    private func buildWalker() {
        let node = person(tint: .labelColor)
        node.position = CGPoint(x: desks[0].x, y: desks[0].y - 24)
        addChild(node)
        walker = node
    }

    /// 手前のものほど後に描く。歩くたびに奥行きが変わるので毎フレーム引き直す
    override func update(_ currentTime: TimeInterval) {
        guard let walker else { return }
        walker.zPosition = -walker.position.y
    }

    // MARK: - 動き

    /// 書類を持って別の机まで歩き、渡して次へ、を延々と繰り返す。
    /// 本番ではここが台帳やadjutantの受け渡しイベントに置き換わる
    private func startRound() {
        guard let walker else { return }

        // 机の手前に立つ位置。天板に重ならないよう少し下げる
        func spot(_ index: Int) -> CGPoint {
            CGPoint(x: desks[index].x, y: desks[index].y - 24)
        }

        var steps: [SKAction] = []
        for target in [1, 4, 5, 2, 3, 6] {
            steps.append(.wait(forDuration: 0.5))
            steps.append(.run { [weak self] in self?.givePaper(to: walker) })
            steps.append(walk(walker, to: spot(target)))
            steps.append(.wait(forDuration: 0.5))
            steps.append(.run { [weak self] in self?.takePaper(from: walker) })
            steps.append(walk(walker, to: spot(0)))
        }
        walker.run(.repeatForever(.sequence(steps)))
    }

    /// 歩行。距離に比例した時間をかけ、上下に小さく跳ねさせて歩いているように見せる。
    /// 同時にカメラを同じ時間で横に追従させる (出来事のある所を映す、の素振り)
    private func walk(_ node: SKNode, to point: CGPoint) -> SKAction {
        SKAction.run { [weak self] in
            guard let self else { return }
            let distance = hypot(node.position.x - point.x, node.position.y - point.y)
            let duration = TimeInterval(distance / 65)

            node.run(.move(to: point, duration: duration))
            // 跳ねは見た目だけのもの。位置そのものを動かすと移動先がずれるので、
            // 頭と胴だけを持つ子ノードではなくスケールで代用する
            node.run(.repeat(
                .sequence([
                    .scaleY(to: 1.04, duration: 0.13),
                    .scaleY(to: 1.0, duration: 0.13),
                ]),
                count: max(1, Int(duration / 0.26))))

            self.eye.run(.moveTo(x: self.clampCameraX(point.x), duration: duration))
        }
    }

    private func givePaper(to node: SKNode) {
        guard node.childNode(withName: "paper") == nil else { return }
        let paper = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 8, height: 10),
                                cornerRadius: 1)
        paper.fillColor = NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.95)  // #ffa726
        paper.strokeColor = .clear
        paper.position = CGPoint(x: 5, y: 6)
        paper.zPosition = 1
        paper.name = "paper"
        node.addChild(paper)
    }

    private func takePaper(from node: SKNode) {
        guard let paper = node.childNode(withName: "paper") else { return }
        // 机に置かれて消える、ところまでを1つの所作として見せる
        paper.run(.sequence([
            .group([.moveBy(x: 6, y: 20, duration: 0.3), .fadeOut(withDuration: 0.3)]),
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
