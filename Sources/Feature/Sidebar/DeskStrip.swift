import SpriteKit
import SwiftUI

/// サイドバー下部に置く作業場の帯。**素振り (spike) であって完成品ではない。**
///
/// 確かめたいのは1つだけ——280pt の帯で、斜め上から見た事務所が「読める」かどうか。
/// 台帳とも adjutant とも繋がっておらず、動いているのは作り物の見取り図である。
///
/// 視点は 2D ゲームでよくある俯瞰 (見下ろしを少し斜めに倒したもの)。
/// 机に天板と前面の2枚を描くこと、手前のものほど後に描くこと、
/// 人が上下にも歩くこと、の3つで奥行きを出している。
/// 部屋は帯より広く、カメラで出来事のある所へ寄せる。
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
        let scene = DeskScene(size: CGSize(width: 280, height: 170))
        scene.scaleMode = .resizeFill
        // NSVisualEffectView の上に載るので、地を塗ると背景のぼかしを塗り潰してしまう
        scene.backgroundColor = .clear
        return scene
    }()
}

/// 事務所の見取り図。hub 1つとその worker で「島」を1つ作る。
///
/// 本番ではここが adjutant の hub 一覧 (`~/.local/state/adjutant/hubs/*.json`) と、
/// その配下の worktree から組み立てられる。素振りの間は作り物を渡している
struct DeskIsland {
    let hub: String
    let workers: [String]
}

/// 斜め上から見た事務所。
final class DeskScene: SKScene {

    // MARK: - 見取り図

    /// 素振り用の作り物。hub 2つ、worker の数を変えて配置の伸び方を見る
    private let islands: [DeskIsland] = [
        DeskIsland(hub: "agent-proctor", workers: ["sidebar", "menu-bar", "ledger", "hooks", "docs"]),
        DeskIsland(hub: "agent-adjutant", workers: ["inbox", "outbox", "worker"]),
    ]

    // MARK: - 寸法
    //
    // 机1つの見た目の大きさから逆算した値。ここを触ると部屋全体が組み直される

    private let deskWidth: CGFloat = 58
    private let deskDepth: CGFloat = 17
    /// worker は2カラム。中心からの振り分け幅。机の幅が 58 なので隣とは 18pt 空く
    private let columnOffset: CGFloat = 38
    /// 列と列の縦の間隔。机の縦の専有 (前面 + 天板 + モニタ + 見出し) がおよそ 46pt
    private let rowSpacing: CGFloat = 56
    /// 島と島の間隔。島の幅 (58 + 76) に通路を足したもの
    private let islandSpacing: CGFloat = 210
    private let sideMargin: CGFloat = 105
    private let topMargin: CGFloat = 40
    private let bottomMargin: CGFloat = 34

    /// worker の縦の段数 (2カラムなので2人で1段)
    private var maxRows: Int {
        max(1, islands.map { ($0.workers.count + 1) / 2 }.max() ?? 1)
    }

    private var roomWidth: CGFloat {
        sideMargin * 2 + islandSpacing * CGFloat(max(0, islands.count - 1))
    }

    private var roomHeight: CGFloat {
        topMargin + bottomMargin + rowSpacing * CGFloat(maxRows)
    }

    /// hub の机を置く高さ。島の頭にあたる
    private var hubY: CGFloat { roomHeight - topMargin }

    private func hubPoint(island: Int) -> CGPoint {
        CGPoint(x: sideMargin + islandSpacing * CGFloat(island), y: hubY)
    }

    /// 島の中の worker の席。左右2カラムに、上の段から詰めていく
    private func workerPoint(island: Int, index: Int) -> CGPoint {
        let center = sideMargin + islandSpacing * CGFloat(island)
        let column: CGFloat = index % 2 == 0 ? -columnOffset : columnOffset
        let row = index / 2
        return CGPoint(x: center + column, y: hubY - rowSpacing * CGFloat(row + 1))
    }

    /// 人が机の前に立つ位置。天板に重ならないよう少し手前に下げる
    private func standing(at desk: CGPoint) -> CGPoint {
        CGPoint(x: desk.x, y: desk.y - 24)
    }

    // MARK: - 状態

    /// SKScene の `camera` に差すノード。出来事のある所へ寄せるために動かす
    private let eye = SKCameraNode()
    /// 歩いている人。島ごとに1人。重なり順を毎フレーム引き直すために持っておく
    private var walkers: [Int: SKNode] = [:]
    /// 実寸が決まってから組み立てる。カメラの可動範囲を帯の大きさから決めているため
    private var built = false

    /// 島ごとの稼働の量。受け渡しが起きるたびに増え、時間とともに減る。
    ///
    /// 本番ではここが「動いているセッションの数 + 直近の受け渡しの回数」になる。
    /// 素振りでは配り終えるたびに 1 足しているだけ
    private var activity: [Double] = []
    /// いまカメラが張り付いている島
    private var focused = 0
    /// 最後に島を乗り換えた時刻。乗り換えの間隔を空けるために持つ
    private var switchedAt: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    /// 稼働の半減期 (秒)。短すぎると1回の受け渡しでカメラが飛ぶ
    private let activityHalfLife: TimeInterval = 12
    /// 一度寄ったら最低これだけは留まる (秒)。
    /// これが無いと、僅差の島どうしでカメラが行ったり来たりして落ち着かない
    private let dwell: TimeInterval = 8
    /// 乗り換えに要る差。1.4 倍以上忙しくないと、カメラは動かない
    private let switchMargin: Double = 1.4

    override func didMove(to view: SKView) {
        addChild(eye)
        camera = eye
        buildIfPossible()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        eye.position = clampCamera(eye.position)
        buildIfPossible()
    }

    private func buildIfPossible() {
        guard !built, size.height > 40 else { return }
        built = true
        activity = Array(repeating: 0, count: islands.count)
        eye.position = clampCamera(hubPoint(island: 0))
        buildRoom()
        for index in islands.indices { startRound(island: index) }
    }

    // MARK: - 組み立て

    private func buildRoom() {
        let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: roomWidth, height: roomHeight))
        floor.fillColor = .secondaryLabelColor.withAlphaComponent(0.06)
        floor.strokeColor = .clear
        floor.zPosition = -10000
        addChild(floor)

        // 床のタイル目。地面がどこにあるかを示すためだけのものなので、うんと薄くする
        let tile: CGFloat = 44
        for x in stride(from: 0, through: roomWidth, by: tile) {
            addChild(hairline(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: roomHeight)))
        }
        for y in stride(from: 0, through: roomHeight, by: tile) {
            addChild(hairline(from: CGPoint(x: 0, y: y), to: CGPoint(x: roomWidth, y: y)))
        }

        // 奥の壁。上端に帯を置くと「奥がある」ことが一目で分かる
        let wallHeight: CGFloat = 18
        let wall = SKShapeNode(rect: CGRect(x: 0, y: roomHeight - wallHeight,
                                            width: roomWidth, height: wallHeight))
        wall.fillColor = .secondaryLabelColor.withAlphaComponent(0.12)
        wall.strokeColor = .clear
        wall.zPosition = -9990
        addChild(wall)

        for (index, island) in islands.enumerated() {
            let hub = deskNode(at: hubPoint(island: index), label: island.hub, isHub: true)
            addChild(hub)
            simulateContext(on: hub, start: Int.random(in: 10...70))

            for (slot, worker) in island.workers.enumerated() {
                let point = workerPoint(island: index, index: slot)
                let desk = deskNode(at: point, label: worker, isHub: false)
                addChild(desk)
                simulateContext(on: desk, start: Int.random(in: 5...85))

                // 席に着いたままの人を何人か。無人の事務所だと俯瞰なのか分かりにくい。
                // 机の奥に置くので、重なり順 (-y) では机より後ろに回る
                guard slot % 2 == 0 else { continue }
                let seated = person(tint: .secondaryLabelColor)
                seated.position = CGPoint(x: point.x, y: point.y + 20)
                seated.zPosition = -seated.position.y
                addChild(seated)
            }
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
    /// hub は幅を広げモニタの色も変えて、島の頭だと分かるようにする
    private func deskNode(at point: CGPoint, label: String, isHub: Bool) -> SKNode {
        let node = SKNode()
        node.position = point
        // 手前のものほど後に描く。人が机の前に立ったときに正しく重なる
        node.zPosition = -point.y

        let width = isHub ? deskWidth + 12 : deskWidth

        let front = SKShapeNode(rect: CGRect(x: -width / 2, y: -deskDepth / 2 - 6,
                                             width: width, height: 7),
                                cornerRadius: 1.5)
        front.fillColor = .secondaryLabelColor.withAlphaComponent(0.32)
        front.strokeColor = .clear
        node.addChild(front)

        let top = SKShapeNode(rect: CGRect(x: -width / 2, y: -deskDepth / 2,
                                           width: width, height: deskDepth),
                              cornerRadius: 2.5)
        top.fillColor = .secondaryLabelColor.withAlphaComponent(isHub ? 0.6 : 0.5)
        top.strokeColor = .clear
        node.addChild(top)

        let screen = SKShapeNode(rect: CGRect(x: -11, y: deskDepth / 2 - 4, width: 22, height: 14),
                                 cornerRadius: 2)
        // 色は Palette と同じ値。素振りの間だけここに直書きしている
        screen.fillColor = isHub
            ? NSColor(red: 0.671, green: 0.533, blue: 0.941, alpha: 0.85)  // #ab88f0
            : NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.8)   // #4fc3f7
        screen.strokeColor = .clear
        node.addChild(screen)

        // 書類の山を載せる器。中身は restack が入れ替える。
        // 天板の右手前に置くのは、モニタ (奥) と見出し (上) のどちらとも重ならない場所だから
        let stack = SKNode()
        stack.name = "stack"
        stack.position = CGPoint(x: width / 2 - 10, y: -4)
        node.addChild(stack)

        let caption = SKLabelNode(text: label)
        caption.fontName = "SFMono-Regular"
        caption.fontSize = 8
        caption.fontColor = .secondaryLabelColor.withAlphaComponent(isHub ? 0.85 : 0.7)
        caption.verticalAlignmentMode = .bottom
        caption.position = CGPoint(x: 0, y: deskDepth / 2 + 12)
        node.addChild(caption)

        return node
    }

    /// 机の上に積む書類の枚数の上限。
    /// これ以上積むと見出しに届くうえ、6段もあれば使用量の増減は十分読める
    private let maxSheets = 6

    /// 机の上の書類の山を積み直す。**コンテキストの使用量を山の高さで出す。**
    ///
    /// 本番では `TaskRecord.contextPercent` をそのまま渡す。
    /// 色の変わり目は `Palette.context` と同じ (50% で橙、80% で赤)。
    /// 数字を読ませるのではなく、机を一瞥して「そろそろ危ない」が分かることを狙っている
    private func restack(_ desk: SKNode, percent: Int) {
        guard let stack = desk.childNode(withName: "stack") else { return }
        stack.removeAllChildren()

        let sheets = Int((Double(min(100, max(0, percent))) / 100 * Double(maxSheets)).rounded())
        guard sheets > 0 else { return }

        let tint: NSColor
        if percent >= 80 {
            tint = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 1)  // #ef5350
        } else if percent >= 50 {
            tint = NSColor(red: 1.0, green: 0.718, blue: 0.302, alpha: 1)    // #ffb74d
        } else {
            tint = NSColor(white: 0.93, alpha: 1)
        }

        for index in 0..<sheets {
            let sheet = SKShapeNode(rect: CGRect(x: -5.5, y: 0, width: 11, height: 2.6),
                                    cornerRadius: 0.5)
            sheet.fillColor = tint.withAlphaComponent(0.9)
            sheet.strokeColor = .black.withAlphaComponent(0.12)
            sheet.lineWidth = 0.5
            // 1枚ずつ横にずらす。きっちり重ねると1枚の板に見えて、枚数が読めない
            sheet.position = CGPoint(x: CGFloat.random(in: -1.5...1.5),
                                     y: CGFloat(index) * 2.6)
            stack.addChild(sheet)
        }
    }

    /// 素振り用に、コンテキストがじわじわ増えて畳まれる様子を作る。
    /// 本番では台帳の更新でそのまま値が変わるので、この仕掛けは要らなくなる
    private func simulateContext(on desk: SKNode, start: Int) {
        var percent = start
        restack(desk, percent: percent)
        desk.run(.repeatForever(.sequence([
            .wait(forDuration: 2.0, withRange: 1.5),
            .run { [weak self, weak desk] in
                guard let self, let desk else { return }
                percent += Int.random(in: 4...11)
                // 使い切ると畳まれて、また少ないところから積み直す
                if percent >= 100 { percent = Int.random(in: 5...20) }
                self.restack(desk, percent: percent)
            },
        ])))
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
        shadow.zPosition = -1
        node.addChild(shadow)

        return node
    }

    override func update(_ currentTime: TimeInterval) {
        // 手前のものほど後に描く。歩くたびに奥行きが変わるので毎フレーム引き直す
        for walker in walkers.values { walker.zPosition = -walker.position.y }

        // 最初のフレームは前回時刻を持たないので、減衰も追従もさせない
        guard lastUpdate > 0 else {
            lastUpdate = currentTime
            switchedAt = currentTime
            return
        }
        let delta = currentTime - lastUpdate
        lastUpdate = currentTime

        decayActivity(by: delta)
        reconsiderFocus(at: currentTime)
        followFocused(by: delta)
    }

    /// 稼働を時間で減らす。フレーム間隔で決めるのは、コマ落ちしても減り方を変えないため
    private func decayActivity(by delta: TimeInterval) {
        let factor = pow(0.5, delta / activityHalfLife)
        for index in activity.indices { activity[index] *= factor }
    }

    /// カメラをどの島に置くかを選び直す。
    ///
    /// 一番稼働の多い島に張り付く。ただし僅差で乗り換えると画面が落ち着かないので、
    /// 「前の島より `switchMargin` 倍は忙しいこと」と「乗り換えてから `dwell` 秒は経つこと」の
    /// 両方を満たしたときだけ動かす
    private func reconsiderFocus(at now: TimeInterval) {
        guard now - switchedAt >= dwell else { return }
        guard let busiest = activity.indices.max(by: { activity[$0] < activity[$1] }) else { return }
        guard busiest != focused else { return }
        guard activity[busiest] > activity[focused] * switchMargin else { return }
        focused = busiest
        switchedAt = now
    }

    /// 張り付いている島の使いをカメラで追う。
    ///
    /// 行き先を都度 `SKAction` で指定すると、次の行き先が決まるたびに前の動きを
    /// 打ち切ることになり、カメラが小刻みに向きを変える。毎フレーム少しずつ寄せると
    /// 人の動きに遅れて付いていく形になり、見ていて落ち着く
    private func followFocused(by delta: TimeInterval) {
        guard let walker = walkers[focused] else { return }
        let target = clampCamera(walker.position)
        // 1秒でおよそ 92% 詰める速さ。フレーム間隔に依らず同じ寄り方になる
        let ratio = 1 - pow(0.08, delta)
        eye.position = CGPoint(x: eye.position.x + (target.x - eye.position.x) * ratio,
                               y: eye.position.y + (target.y - eye.position.y) * ratio)
    }

    // MARK: - 動き

    /// hub の使いが書類を持って worker の机を順に回る。島ごとに1人。
    /// 本番ではここが台帳や adjutant の受け渡しイベントに置き換わる
    private func startRound(island index: Int) {
        let island = islands[index]
        guard !island.workers.isEmpty else { return }

        let home = standing(at: hubPoint(island: index))
        let walker = person(tint: .labelColor)
        walker.position = home
        addChild(walker)
        walkers[index] = walker

        var steps: [SKAction] = []
        for slot in island.workers.indices {
            let target = standing(at: workerPoint(island: index, index: slot))
            steps.append(.wait(forDuration: 0.5))
            steps.append(.run { [weak self] in self?.givePaper(to: walker) })
            steps.append(walk(walker, to: target))
            steps.append(.wait(forDuration: 0.5))
            steps.append(.run { [weak self] in
                self?.takePaper(from: walker)
                // 1件配り終えた。カメラはこの数の多い島に張り付く
                self?.activity[index] += 1
            })
            steps.append(walk(walker, to: home))
            // 配り終えてからの間合いを毎回ばらつかせる。
            // 片方を固定で速くすると忙しさの順位が変わらず、カメラの乗り換えが
            // 一度も起きないので、規則が効いているのか確かめられない
            steps.append(.wait(forDuration: 1.3, withRange: 2.2))
        }
        // 島ごとに出発をずらす。同時に動くとカメラの取り合いが常に起きて落ち着かない
        walker.run(.sequence([
            .wait(forDuration: TimeInterval(index) * 1.7),
            .repeatForever(.sequence(steps)),
        ]))
    }

    /// 歩行。距離に比例した時間をかけ、小さく伸び縮みさせて歩いているように見せる。
    /// 同時にカメラを同じ時間で追従させる (出来事のある所を映す、の素振り)
    private func walk(_ node: SKNode, to point: CGPoint) -> SKAction {
        SKAction.run {
            let distance = hypot(node.position.x - point.x, node.position.y - point.y)
            let duration = TimeInterval(distance / 65)

            node.run(.move(to: point, duration: duration))
            // 跳ねは見た目だけのもの。位置そのものを動かすと移動先がずれるので、
            // 座標ではなく縦の伸縮で代用する
            node.run(.repeat(
                .sequence([
                    .scaleY(to: 1.04, duration: 0.13),
                    .scaleY(to: 1.0, duration: 0.13),
                ]),
                count: max(1, Int(duration / 0.26))))
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
    /// ビューポートが部屋より広い軸は寄せようがないので、部屋の中央に置く
    private func clampCamera(_ point: CGPoint) -> CGPoint {
        func fit(_ value: CGFloat, room: CGFloat, view: CGFloat) -> CGFloat {
            guard room > view else { return room / 2 }
            return min(max(value, view / 2), room - view / 2)
        }
        return CGPoint(x: fit(point.x, room: roomWidth, view: size.width),
                       y: fit(point.y, room: roomHeight, view: size.height))
    }
}
