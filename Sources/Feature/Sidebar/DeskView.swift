import Model
import SpriteKit
import SwiftUI

/// 作業場の俯瞰。一覧と同じ台帳を、机を並べた部屋として見せる。
///
/// 視点は 2D ゲームでよくある俯瞰 (見下ろしを少し斜めに倒したもの)。
/// 机に天板と前面の2枚を描くこと、手前のものほど後に描くこと、
/// 人が上下にも歩くこと、の3つで奥行きを出している。
/// 部屋はビューポートより広いことがあり、そのぶんはカメラで送る。
struct DeskView: View {
    let islands: [DeskIsland]
    /// サイドバーが見えているか。隠れているあいだはコマ数を落とす
    let running: Bool
    /// 机をクリックしたときに開くセッション。一覧の行クリックと同じ相手を渡す
    var onOpen: (String) -> Void

    /// SwiftUI の再描画のたびにシーンが作り直されると、歩いている途中の人が
    /// 毎回入口に戻ってしまう。参照を1つ持ち続けるために箱に入れる
    @StateObject private var box = SceneBox()

    var body: some View {
        // **止めるのではなくコマ数を落とす。**
        // `isPaused` で止めると、一度も描かないうちに止まった場合に
        // シーンが出ないまま view の地色 (白) が出る。アプリを立ち上げ直した直後は
        // サイドバーがまだ「見えている」と分かっていないので、必ずそこに落ちる。
        // 2fps なら常駐していても負荷はほぼ無く、描かれないことも無い
        SpriteView(scene: box.scene,
                   preferredFramesPerSecond: running ? 60 : 2,
                   options: [.allowsTransparency])
            .onAppear {
                box.scene.onOpen = onOpen
                box.scene.apply(islands: islands)
            }
            .onChange(of: islands) { islands in
                box.scene.apply(islands: islands)
            }
            // 止まっている間は台帳の変化も大きさの変化も取りこぼす。
            // 動き出す時点でもう一度当て直さないと、止まる前の姿のまま再開する
            .onChange(of: running) { running in
                guard running else { return }
                box.scene.apply(islands: islands)
            }
    }
}

private final class SceneBox: ObservableObject {
    /// 初期サイズは仮。`scaleMode = .resizeFill` なので実際の大きさに合わせ直される
    let scene: DeskScene = {
        let scene = DeskScene(size: CGSize(width: 280, height: 600))
        scene.scaleMode = .resizeFill
        // NSVisualEffectView の上に載るので、地を塗ると背景のぼかしを塗り潰してしまう
        scene.backgroundColor = .clear
        return scene
    }()
}

// MARK: - 見取り図

/// 机1つ。台帳の1セッションに対応する
struct DeskSeat: Equatable {
    /// `CollectedTask.id`。クリックで開く相手
    let id: String
    let name: String
    /// `CollectedTask.displayStatus`
    let status: String
    /// 人の手が要るか (`TaskStatus.needsPerson`)。カメラがここを最優先で映す
    let needsPerson: Bool
    let contextPercent: Int?
    let subagents: Int
}

/// リポジトリ1つ分の島。見出しの机 (hub) と、その下に並ぶセッションの机。
///
/// adjutant を繋いだら hub は本物の hub セッションになる。
/// いまはリポジトリの名札で、座っている人はいない
struct DeskIsland: Equatable {
    let repo: String
    let seats: [DeskSeat]
}

// MARK: - シーン

/// 斜め上から見た事務所。
final class DeskScene: SKScene {

    var onOpen: ((String) -> Void)?

    // MARK: 寸法
    //
    // 机1つの見た目の大きさから逆算した値。ここを触ると部屋全体が組み直される

    private let deskWidth: CGFloat = 88
    private let deskDepth: CGFloat = 25
    /// 机を横に何列並べるか。**帯の幅で 1〜3 列に変わる。**
    ///
    /// 固定にすると、広げたときは横が余り、狭めたときは見出しが隣とぶつかる。
    /// 3 列を上限にしているのは、それ以上に細くすると見出しが縦長になって読めないため
    private var seatColumns: Int {
        max(1, min(3, Int(size.width / 130)))
    }

    /// 列と列の間隔。帯の幅を使い切るが、広げすぎると机がまばらになるので上限を置く
    private var columnPitch: CGFloat {
        min(200, max(120, (size.width - 30) / CGFloat(seatColumns)))
    }

    /// 見出しを折り返す幅。列の間隔より 18pt 狭くして、隣と触れないようにする
    private var captionWidth: CGFloat { columnPitch - 18 }

    /// 島1つの横幅。机の幅に、列を広げたぶんを足したもの
    private var islandWidth: CGFloat {
        deskWidth + columnPitch * CGFloat(seatColumns - 1)
    }
    /// 見出しの行数。これ以上増やすと下の段のモニタに乗る
    private let captionLines = 3
    /// 見出しの文字の大きさ。長い名前はここから縮めて3行に収める
    private let captionSize: CGFloat = 12
    /// 縮める下限。これ以下にすると読めないので、そこから先は諦めて切る
    private let captionMinSize: CGFloat = 8
    /// 段と段の縦の間隔。
    /// 机の縦の専有 (前面 16.5 + 3行の見出し 36) と、下の段のモニタの天 (23.5) が
    /// 余裕をもって離れる高さを取る。ここを詰めると、名前の長い机の3行目が
    /// 下の段のモニタに乗る
    private let rowSpacing: CGFloat = 116
    /// 島と島の横の間隔。島の幅に通路を足したもの
    private var islandSpacing: CGFloat { islandWidth + 80 }
    /// 部屋の上の余白。hub の見出し (机から 32pt 上) が奥の壁に食い込まない高さに、
    /// 天井側の間を足したもの。ここが詰まっていると机が上端に貼り付いて窮屈に見える
    private let topMargin: CGFloat = 84
    private let bottomMargin: CGFloat = 34

    /// 片側に積む書類の枚数の上限。左右で倍の 12 段まで出せる。
    /// これ以上高くすると見出しに届く
    private let maxSheetsPerSide = 6
    private let sheetWidth: CGFloat = 18
    private let sheetHeight: CGFloat = 5

    // MARK: 状態

    private var islands: [DeskIsland] = []
    /// いま組み上がっている部屋の骨格。これが変わったときだけ組み直す
    private var builtSkeleton: String?
    /// 組み上げたときの島のカラム数。幅を変えて段が変わったら組み直す
    private var builtColumns = 0
    /// 組み上げたときの机の列数
    private var builtSeatColumns = 0
    /// 組み上げたときの部屋の大きさ。
    ///
    /// 部屋はビューポートより小さくならない (`max(size, ...)`) ので、帯の大きさが
    /// 変わると部屋の大きさも変わる。机の座標は組んだときのままなのに、
    /// カメラの可動範囲だけ新しい部屋で計算されると、**机が部屋の左下に取り残される**。
    /// SwiftUI が実寸を入れてくるのは最初の組み立てのあとなので、これは必ず起きる
    private var builtRoom: CGSize = .zero

    /// SKScene の `camera` に差すノード。出来事のある所へ寄せるために動かす
    private let eye = SKCameraNode()
    /// 画面外の要確認を指す印を載せる器。カメラの子なので常に画面に貼り付く
    private let markers = SKNode()
    /// 部屋のものを全部ぶら下げる。組み直しはこれを捨てるだけで済む
    private var room = SKNode()

    /// hub へ質問しに来ている人。席の id で引く。
    /// 机の occupant とは別のノードで、部屋の座標で歩かせる
    private var visitors: [String: SKNode] = [:]
    /// 島ごとの稼働の量。いま動いているセッションの数を秒単位でならしたもの
    private var activity: [Double] = []
    /// いまカメラが張り付いている先
    private var focus: CGPoint = .zero
    private var focusedIsland = 0
    private var switchedAt: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0
    /// 最後に画面外の印を引き直した時刻
    private var markedAt: TimeInterval = 0

    /// 一度寄ったら最低これだけは留まる (秒)。
    /// これが無いと、僅差の島どうしでカメラが行ったり来たりして落ち着かない
    private let dwell: TimeInterval = 8
    /// 乗り換えに要る差。1.4 倍以上忙しくないと、カメラは動かない
    private let switchMargin: Double = 1.4

    override func didMove(to view: SKView) {
        if eye.parent == nil {
            addChild(eye)
            camera = eye
            eye.addChild(markers)
        }
        rebuildIfNeeded()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        rebuildIfNeeded()
    }

    // MARK: - 受け取り

    /// 台帳の中身を反映する。
    ///
    /// 骨格 (島と机の顔ぶれ) が同じなら組み直さず、机の見た目だけ差し替える。
    /// 状態が変わるたびに部屋を作り直すと、歩いている人が毎回入口に戻ってしまう
    func apply(islands: [DeskIsland]) {
        self.islands = islands
        if !rebuildIfNeeded() { refreshSeats() }
    }

    /// 部屋の骨格。机の顔ぶれと並び順だけを見て、状態や使用量は含めない
    private func skeleton(of islands: [DeskIsland]) -> String {
        islands.map { "\($0.repo)/\($0.seats.map(\.id).joined(separator: ","))" }
            .joined(separator: "|")
    }

    /// 組み直しが要るなら組み直す。組み直したかどうかを返す
    @discardableResult
    private func rebuildIfNeeded() -> Bool {
        // 島が無くても床は組む。立ち上げ直後は台帳がまだ読めていないので、
        // 島が揃うまで何も描かないと、そのあいだ地色が出る
        guard size.height > 80 else { return false }
        let wanted = CGSize(width: roomWidth, height: roomHeight)
        guard skeleton(of: islands) != builtSkeleton
                || columns != builtColumns
                || seatColumns != builtSeatColumns
                || abs(wanted.width - builtRoom.width) > 1
                || abs(wanted.height - builtRoom.height) > 1
        else { return false }
        rebuild()
        return true
    }

    // MARK: - 座席の割り当て

    /// 横に何島並べられるか。広げれば増え、狭ければ1島ずつ縦に積む
    private var columns: Int {
        max(1, Int(size.width / islandSpacing))
    }

    private var islandRows: Int {
        max(1, (islands.count + columns - 1) / columns)
    }

    /// どの島も同じ高さの区画を取る。島ごとに高さを変えると、
    /// 机が増減するたびに下の島がまるごと動いて落ち着かない
    private var islandHeight: CGFloat {
        let seatRows = islands.map {
            ($0.seats.count + seatColumns - 1) / seatColumns
        }.max() ?? 1
        return rowSpacing * CGFloat(max(1, seatRows) + 1)
    }

    private var roomWidth: CGFloat {
        max(size.width, islandSpacing * CGFloat(columns))
    }

    private var roomHeight: CGFloat {
        max(size.height, topMargin + bottomMargin + islandHeight * CGFloat(islandRows))
    }

    /// 島の見出し (hub) の机の位置
    private func hubPoint(island: Int) -> CGPoint {
        let column = CGFloat(island % columns)
        let row = CGFloat(island / columns)
        let spread = islandSpacing * CGFloat(columns - 1)
        return CGPoint(x: roomWidth / 2 - spread / 2 + islandSpacing * column,
                       y: roomHeight - topMargin - islandHeight * row)
    }

    /// 島の中の机。上の段から、左から順に詰めていく
    private func seatPoint(island: Int, index: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        let spread = columnPitch * CGFloat(seatColumns - 1)
        return CGPoint(x: hub.x - spread / 2 + columnPitch * CGFloat(index % seatColumns),
                       y: hub.y - rowSpacing * CGFloat(index / seatColumns + 1))
    }

    /// 人が机の前に立つ位置。天板に重ならないよう少し手前に下げる
    private func standing(at desk: CGPoint) -> CGPoint {
        CGPoint(x: desk.x, y: desk.y - 34)
    }

    // MARK: - 組み立て

    private func rebuild() {
        guard size.height > 80 else { return }
        // 島が1つも無いときは hubPoint(0) を焦点に置く。部屋の左上あたりになる
        room.removeFromParent()
        room = SKNode()
        addChild(room)
        visitors.removeAll()
        activity = Array(repeating: 0, count: islands.count)
        builtSkeleton = skeleton(of: islands)
        builtColumns = columns
        builtSeatColumns = seatColumns
        builtRoom = CGSize(width: roomWidth, height: roomHeight)

        buildFloor()
        for (index, island) in islands.enumerated() {
            room.addChild(deskNode(at: hubPoint(island: index), label: island.repo,
                                   isHub: true, seat: nil))
            for (slot, seat) in island.seats.enumerated() {
                room.addChild(deskNode(at: seatPoint(island: index, index: slot),
                                       label: seat.name, isHub: false, seat: seat))
            }
        }
        refreshSeats()

        focusedIsland = min(focusedIsland, max(0, islands.count - 1))
        focus = hubPoint(island: focusedIsland)
        eye.position = clampCamera(focus)
    }

    private func buildFloor() {
        let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: roomWidth, height: roomHeight))
        floor.fillColor = .secondaryLabelColor.withAlphaComponent(0.06)
        floor.strokeColor = .clear
        floor.zPosition = -10000
        room.addChild(floor)

        // 床のタイル目。地面がどこにあるかを示すためだけのものなので、うんと薄くする
        let tile: CGFloat = 44
        for x in stride(from: 0, through: roomWidth, by: tile) {
            room.addChild(hairline(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: roomHeight)))
        }
        for y in stride(from: 0, through: roomHeight, by: tile) {
            room.addChild(hairline(from: CGPoint(x: 0, y: y), to: CGPoint(x: roomWidth, y: y)))
        }

        // 奥の壁。上端に帯を置くと「奥がある」ことが一目で分かる
        let wallHeight: CGFloat = 18
        let wall = SKShapeNode(rect: CGRect(x: 0, y: roomHeight - wallHeight,
                                            width: roomWidth, height: wallHeight))
        wall.fillColor = .secondaryLabelColor.withAlphaComponent(0.12)
        wall.strokeColor = .clear
        wall.zPosition = -9990
        room.addChild(wall)
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
    /// hub は幅を広げて、島の頭だと分かるようにする
    private func deskNode(at point: CGPoint, label: String,
                          isHub: Bool, seat: DeskSeat?) -> SKNode {
        let node = SKNode()
        node.position = point
        // 手前のものほど後に描く。人が机の前に立ったときに正しく重なる
        node.zPosition = -point.y
        // クリックの当たり判定はこの名前で引く。hub には開く相手がいない
        if let seat { node.name = "seat:\(seat.id)" }

        let width = isHub ? deskWidth + 12 : deskWidth

        let front = SKShapeNode(rect: CGRect(x: -width / 2, y: -deskDepth / 2 - 8,
                                             width: width, height: 9),
                                cornerRadius: 2)
        front.fillColor = .secondaryLabelColor.withAlphaComponent(0.32)
        front.strokeColor = .clear
        node.addChild(front)

        let top = SKShapeNode(rect: CGRect(x: -width / 2, y: -deskDepth / 2,
                                           width: width, height: deskDepth),
                              cornerRadius: 2.5)
        top.fillColor = .secondaryLabelColor.withAlphaComponent(isHub ? 0.6 : 0.5)
        top.strokeColor = .clear
        node.addChild(top)

        let screen = SKShapeNode(rect: CGRect(x: -16.5, y: deskDepth / 2 - 4,
                                              width: 33, height: 20),
                                 cornerRadius: 3)
        screen.name = "screen"
        screen.strokeColor = .clear
        screen.fillColor = .secondaryLabelColor.withAlphaComponent(0.4)
        node.addChild(screen)

        // 書類の山を載せる器。中身は restack が入れ替える。
        // 天板の両端に置くのは、モニタ (奥) と見出し (上) のどちらとも重ならない場所だから。
        // 片側に積み上げるより、半分ずつ左右に分けたほうが低い山で同じ量を出せる
        for (name, side) in [("stackL", -1.0), ("stackR", 1.0)] as [(String, CGFloat)] {
            let stack = SKNode()
            stack.name = name
            stack.position = CGPoint(x: side * (width / 2 - 13), y: -6)
            node.addChild(stack)
        }

        // 席の人。hub にも座らせる。質問を受ける相手がいない事務所だと、
        // 並びに来た人が誰に用があるのか分からない
        let occupant = person(tint: isHub ? .labelColor : .labelColor)
        occupant.name = "occupant"
        occupant.position = CGPoint(x: 0, y: 28)
        occupant.zPosition = -20
        node.addChild(occupant)

        if seat != nil {
            // 挙げた手。**机の上に置いたままにする。**
            // 本人は hub へ質問しに行ってしまうので、手が付いていってしまうと
            // どの机が呼んでいるのか分からなくなる
            let hand = DeskScene.handMark()
            hand.name = "hand"
            hand.position = CGPoint(x: 0, y: -4)
            hand.zPosition = 5
            hand.isHidden = true
            node.addChild(hand)
        }

        // 見出しは机の下、最大3行。上に置くと書類の山 (片側6枚 24pt) と場所を
        // 取り合ううえ、名前が長いと隣の机の見出しとぶつかる。
        // 折り返しは文字単位にしている。セッション名はハイフン続きで空白が無いことが多く、
        // 単語単位だと折り返す場所が見つからずに幅をはみ出す
        let size = captionFontSize(for: label)
        let caption = SKLabelNode(text: wrapped(label, size: size))
        caption.name = "caption"
        caption.fontName = "SFMono-Regular"
        caption.fontSize = size
        caption.fontColor = .secondaryLabelColor.withAlphaComponent(isHub ? 0.85 : 0.7)
        // 折り返しは自分で入れた改行でやる。行数は数えてあるので上限は要らない
        caption.numberOfLines = 0
        caption.verticalAlignmentMode = .top
        caption.position = CGPoint(x: 0, y: -deskDepth / 2 - 12)
        node.addChild(caption)

        return node
    }

    /// 見出しの文字の大きさを決める。
    ///
    /// `SKLabelNode` は入りきらない分を「…」で切る。行数を増やせば入るが、
    /// 増やすと下の段のモニタに乗るので、**行数は据え置きで文字のほうを縮める**。
    ///
    /// 幅の見積もりは、等幅の欧文がおよそ文字送り 0.6 文字ぶん、
    /// 和文が 1 文字ぶんであることから出している。
    /// 実測しないのは、机ごとに `NSAttributedString` を測ると
    /// 台帳が流れてくるたびに全部の机で測り直すことになるため
    private func captionFontSize(for label: String) -> CGFloat {
        let units = label.reduce(CGFloat(0)) { $0 + ($1.isASCII ? 0.6 : 1.0) }
        guard units > 0 else { return captionSize }
        // 1行に入るのは (幅 ÷ 文字送り) 文字。それが captionLines 行ぶんあればよい
        let fits = captionWidth * CGFloat(captionLines) / units
        return max(captionMinSize, min(captionSize, (fits * 2).rounded(.down) / 2))
    }

    /// 見出しを自分で折り返す。
    ///
    /// `SKLabelNode` の `preferredMaxLayoutWidth` による折り返しは**空白でしか折れない**。
    /// セッション名はハイフン続きだったり和文だったりで空白が無いことが多く、
    /// 折る場所が見つからないまま行数を使い切って「…」で切られてしまう
    /// (`lineBreakMode` を `.byCharWrapping` にしても変わらない)。
    /// 改行を自分で入れてしまえば、どんな文字列でも同じところで折れる。
    ///
    /// 幅の見積もりは `captionFontSize(for:)` と同じ根拠 (欧文 0.6 / 和文 1.0)
    private func wrapped(_ label: String, size: CGFloat) -> String {
        let capacity = captionWidth / size
        var lines: [String] = []
        var current = ""
        var used: CGFloat = 0
        var cut = false

        for character in label {
            let advance: CGFloat = character.isASCII ? 0.6 : 1.0
            if used + advance > capacity, !current.isEmpty {
                // 最後の行まで使い切った。ここから先は入らない
                if lines.count == captionLines - 1 {
                    cut = true
                    break
                }
                lines.append(current)
                current = ""
                used = 0
            }
            current.append(character)
            used += advance
        }
        lines.append(current)

        // 入りきらなかったことを示す。1文字返してから「…」を置く
        if cut, var last = lines.last, !last.isEmpty {
            last.removeLast()
            lines[lines.count - 1] = last + "…"
        }
        return lines.joined(separator: "\n")
    }

    /// 挙げた手。
    ///
    /// 記号ではなく SF Symbols の `hand.raised.fill` を使うのは、
    /// メニューバーの `StatusGlyph` が待機中に出すものと同じだから。
    /// 同じ状態を別の絵で言うと、どちらかが別の意味に見える。
    /// SpriteKit は記号をそのまま置けないので、色を焼いた画像にしてから貼る
    private static let handTexture: SKTexture? = {
        let config = NSImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: "hand.raised.fill",
                                   accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.systemOrange.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return SKTexture(image: tinted)
    }()

    private static func handMark() -> SKNode {
        guard let handTexture else { return SKNode() }
        let node = SKSpriteNode(texture: handTexture)
        node.size = CGSize(width: 21, height: 25)
        return node
    }

    /// モニタに流す行。
    ///
    /// 人の小さな上下だけでは「動いている」ことが伝わらない。
    /// 画面の中身が変わるのが、機械が仕事をしていることの一番わかりやすい印。
    /// 中身そのものに意味は無いので、幅を振り直すだけにしている
    private func startScreenLines(on screen: SKShapeNode) {
        guard screen.childNode(withName: "lines") == nil else { return }
        let lines = SKNode()
        lines.name = "lines"
        lines.zPosition = 1
        screen.addChild(lines)

        let inset: CGFloat = 3.5
        let height: CGFloat = 2
        let top = deskDepth / 2 - 4 + 20 - inset - height
        let usable = 33 - inset * 2

        for index in 0..<4 {
            let bar = SKShapeNode(rect: CGRect(x: 0, y: 0, width: usable, height: height),
                                  cornerRadius: 0.8)
            bar.fillColor = .white.withAlphaComponent(0.55)
            bar.strokeColor = .clear
            bar.position = CGPoint(x: -16.5 + inset, y: top - CGFloat(index) * (height + 2.2))
            bar.xScale = CGFloat.random(in: 0.25...1.0)
            lines.addChild(bar)

            // 行ごとに間合いをずらす。揃って伸び縮みすると点滅にしか見えない
            bar.run(.sequence([
                .wait(forDuration: Double(index) * 0.11),
                .repeatForever(.sequence([
                    .run { bar.xScale = CGFloat.random(in: 0.25...1.0) },
                    .wait(forDuration: 0.34, withRange: 0.24),
                ])),
            ]), withKey: "type")
        }
    }

    private func stopScreenLines(on screen: SKShapeNode) {
        screen.childNode(withName: "lines")?.removeFromParent()
    }

    /// 机まわりのサブエージェント。
    ///
    /// 一覧では机の下に小さく畳むしかないが、俯瞰なら人を増やすだけで
    /// 「この机は何人がかりで動いている」が一目で分かる。ここは俯瞰の独壇場
    private func setHelpers(_ desk: SKNode, count: Int, tint: NSColor) {
        // 4人まで。机の左右に振り分けて、足りなければ後ろの段へ回す。
        // それ以上出しても、机の間隔 (列の間隔は最小 120pt) に収まらない
        let shown = min(4, max(0, count))
        for index in 0..<4 {
            let name = "helper\(index)"
            let existing = desk.childNode(withName: name)
            guard index < shown else {
                existing?.removeFromParent()
                continue
            }
            guard existing == nil else { continue }

            let helper = person(tint: tint)
            helper.name = name
            helper.setScale(0.62)
            let side: CGFloat = index % 2 == 0 ? -1 : 1
            helper.position = CGPoint(x: side * (deskWidth / 2 + 12),
                                      y: index < 2 ? 4 : 26)
            helper.zPosition = 10
            helper.alpha = 0.8
            desk.addChild(helper)

            // 少しずつ揺らす。止まっていると置物に見える
            helper.run(.sequence([
                .wait(forDuration: Double(index) * 0.2),
                .repeatForever(.sequence([
                    .moveBy(x: 0, y: 1.5, duration: 0.38),
                    .moveBy(x: 0, y: -1.5, duration: 0.38),
                ])),
            ]), withKey: "fidget")
        }
    }

    /// 人1人。俯瞰なので背丈は詰めて、頭を大きめに取る
    private func person(tint: NSColor) -> SKNode {
        let node = SKNode()

        let body = SKShapeNode(rect: CGRect(x: -7, y: 0, width: 14, height: 18),
                               cornerRadius: 6)
        body.fillColor = tint.withAlphaComponent(0.75)
        body.strokeColor = .clear
        node.addChild(body)

        let head = SKShapeNode(circleOfRadius: 7)
        head.fillColor = tint.withAlphaComponent(0.85)
        head.strokeColor = .clear
        head.position = CGPoint(x: 0, y: 21)
        node.addChild(head)

        // 足元の影。地面に立っていることを示す
        let shadow = SKShapeNode(ellipseOf: CGSize(width: 19, height: 7))
        shadow.fillColor = .black.withAlphaComponent(0.14)
        shadow.strokeColor = .clear
        shadow.zPosition = -1
        node.addChild(shadow)

        return node
    }

    // MARK: - 状態の反映

    /// 机の見た目を台帳に合わせる。骨格が変わっていないときはここだけ走る
    private func refreshSeats() {
        var queued: Set<String> = []
        for (index, island) in islands.enumerated() {
            for seat in island.seats {
                guard let desk = room.childNode(withName: "seat:\(seat.id)") else { continue }
                dress(desk, as: seat)
            }
            queued.formUnion(updateQueue(island: index))
        }
        // 片付けは全島ぶんを集めてから1度だけ。島ごとにやると、その島で待っていない人
        // ——つまり他の島で並んでいる人——を片端から席へ帰してしまう
        dismissVisitors(keeping: queued)
    }

    /// 状態を絵にする。記号 (⏳▶✅) の代わりに、机の様子で言う。
    ///
    /// 台帳は 0.5 秒ごとに流れてくるが、見た目が同じなら何もしない。
    /// 毎回描き直すと、紙の山のばらつきが振り直されてチラつき、
    /// 打鍵の上下も 0.5 秒ごとに位置を戻されてしまう
    private func dress(_ desk: SKNode, as seat: DeskSeat) {
        let signature = "\(seat.status)/\(seat.needsPerson)/\(seat.contextPercent ?? -1)/\(seat.subagents)"
        if desk.userData?["dressed"] as? String == signature { return }
        if desk.userData == nil { desk.userData = NSMutableDictionary() }
        desk.userData?["dressed"] = signature

        let screen = desk.childNode(withName: "screen") as? SKShapeNode
        let occupant = desk.childNode(withName: "occupant")
        let hand = desk.childNode(withName: "hand")

        // 席に人がいるかどうか。
        //
        // 立ち上げただけで何も指示していないもの (idle) と、動いていた場所が
        // 消えたもの (missing) だけ席を空ける。それ以外は、終わったあとも
        // 確認を待っているあいだは人がいる。誰もいない机は「ここには誰もいない」
        // という意味に読めてほしいので、その意味を持たない状態には使わない
        // 待機中は本人が hub へ質問しに行っているので、席にはいない
        let seated = seat.status != TaskStatus.idle
            && seat.status != TaskStatus.missing
            && seat.status != TaskStatus.waiting
        occupant?.isHidden = !seated

        // 人の手が要るものだけ手を挙げる。動いているだけのものに出すと、
        // 本当に呼ばれているものが埋もれる
        hand?.isHidden = !seat.needsPerson
        if seat.needsPerson, hand?.action(forKey: "wave") == nil {
            hand?.run(.repeatForever(.sequence([
                .rotate(toAngle: 0.22, duration: 0.4),
                .rotate(toAngle: -0.12, duration: 0.4),
            ])), withKey: "wave")
        } else if !seat.needsPerson {
            hand?.removeAction(forKey: "wave")
            hand?.zRotation = 0
        }

        occupant?.removeAction(forKey: "type")
        occupant?.alpha = 1
        if let screen, seat.status != TaskStatus.running { stopScreenLines(on: screen) }
        // 手伝いが出るのは動いている間だけ。止まった机に人だけ残ると、
        // まだ動いているように見える
        setHelpers(desk,
                   count: seat.status == TaskStatus.running ? seat.subagents : 0,
                   tint: .labelColor)
        // 座っているときは机の奥。立っているときは机の手前なので、重なりも入れ替える
        occupant?.position = CGPoint(x: 0, y: 28)
        occupant?.zPosition = -20

        switch seat.status {
        case TaskStatus.running:
            screen?.fillColor = NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.85)
            if let screen { startScreenLines(on: screen) }
            // 打鍵の代わりの小さな上下。動いていることを一目で分かるようにする
            occupant?.run(.repeatForever(.sequence([
                .moveBy(x: 0, y: 1.2, duration: 0.32),
                .moveBy(x: 0, y: -1.2, duration: 0.32),
            ])), withKey: "type")
        case TaskStatus.waiting:
            screen?.fillColor = NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.9)
        case TaskStatus.done:
            screen?.fillColor = NSColor(red: 0.400, green: 0.733, blue: 0.416, alpha: 0.8)
        case TaskStatus.failed:
            screen?.fillColor = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 0.85)
        case TaskStatus.seen:
            // 確認が済んだもの。人は残すが、まだ見ていない完了と区別するため色を落とす
            screen?.fillColor = .secondaryLabelColor.withAlphaComponent(0.3)
            occupant?.alpha = 0.5
        default:
            // idle / missing。画面は暗く、席は空
            screen?.fillColor = .secondaryLabelColor.withAlphaComponent(0.3)
        }

        desk.alpha = seat.status == TaskStatus.missing ? 0.45 : 1
        restack(desk, percent: seat.contextPercent ?? 0)
    }

    /// 机の上の書類の山を積み直す。**コンテキストの使用量を山の高さで出す。**
    ///
    /// 色の変わり目は `Palette.context` と同じ (50% で橙、80% で赤)。
    /// 数字を読ませるのではなく、机を一瞥して「そろそろ危ない」が分かることを狙っている
    private func restack(_ desk: SKNode, percent: Int) {
        let capped = min(100, max(0, percent))
        let total = Int((Double(capped) / 100 * Double(maxSheetsPerSide * 2)).rounded())

        let tint: NSColor
        if capped >= 80 {
            tint = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 1)  // #ef5350
        } else if capped >= 50 {
            tint = NSColor(red: 1.0, green: 0.718, blue: 0.302, alpha: 1)    // #ffb74d
        } else {
            tint = NSColor(white: 0.93, alpha: 1)
        }

        // 左から1枚ずつ交互に積む。左右の高さが1枚差までしか開かないので、
        // どちらを見ても使用量が読める
        pile(desk, name: "stackL", sheets: (total + 1) / 2, tint: tint)
        pile(desk, name: "stackR", sheets: total / 2, tint: tint)
    }

    private func pile(_ desk: SKNode, name: String, sheets: Int, tint: NSColor) {
        guard let stack = desk.childNode(withName: name) else { return }
        stack.removeAllChildren()
        guard sheets > 0 else { return }

        for index in 0..<sheets {
            let sheet = SKShapeNode(
                rect: CGRect(x: -sheetWidth / 2, y: 0, width: sheetWidth, height: sheetHeight),
                cornerRadius: 0.5)
            sheet.fillColor = tint.withAlphaComponent(0.9)
            sheet.strokeColor = .black.withAlphaComponent(0.14)
            sheet.lineWidth = 0.5
            // 1枚ずつ横にずらす。きっちり重ねると1枚の板に見えて、枚数が読めない
            sheet.position = CGPoint(x: CGFloat.random(in: -1.6...1.6),
                                     y: CGFloat(index) * sheetHeight)
            stack.addChild(sheet)
        }
    }

    // MARK: - 質問の行列

    /// hub の席の人の横の並び位置。
    ///
    /// **席の人と同じ高さ**に、左へ1人ずつ並べる。机の手前 (下) に置くと
    /// 机を挟んで向かい合う形になり、話しているようには見えない。
    /// 島の幅は 290pt あるので、5人までは隣の島に食い込まない
    private func queuePoint(island: Int, slot: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        return CGPoint(x: hub.x - 30 - CGFloat(slot) * 24, y: hub.y + 28)
    }

    /// 待っている人を hub の前に並ばせる。
    ///
    /// 手は机に置いたまま本人だけが来る。並ぶ順は席の並び順なので、
    /// 誰かの番が済んでも残りの並びが入れ替わらない
    @discardableResult
    private func updateQueue(island index: Int) -> Set<String> {
        let island = islands[index]
        var slot = 0
        var standing = Set<String>()

        for (seatIndex, seat) in island.seats.enumerated()
        where seat.status == TaskStatus.waiting {
            standing.insert(seat.id)
            let target = queuePoint(island: index, slot: slot)
            slot += 1

            let visitor: SKNode
            if let existing = visitors[seat.id] {
                visitor = existing
            } else {
                // 席から立ち上がったところから歩き出す
                visitor = person(tint: .labelColor)
                visitor.position = standingSpot(island: index, seat: seatIndex)
                room.addChild(visitor)
                visitors[seat.id] = visitor
            }
            send(visitor, to: target)
        }
        return standing
    }

    /// 並ぶ用の無くなった人を席へ帰す
    private func dismissVisitors(keeping queued: Set<String>) {
        for (id, visitor) in visitors where !queued.contains(id) {
            visitors.removeValue(forKey: id)
            guard let home = homeSpot(of: id) else {
                visitor.removeFromParent()
                continue
            }
            let distance = hypot(visitor.position.x - home.x, visitor.position.y - home.y)
            visitor.run(.sequence([
                .move(to: home, duration: max(0.3, TimeInterval(distance / 70))),
                .removeFromParent(),
            ]))
        }
    }

    private func standingSpot(island: Int, seat: Int) -> CGPoint {
        standing(at: seatPoint(island: island, index: seat))
    }

    /// 席へ帰る先。机がもう無ければ nil
    private func homeSpot(of id: String) -> CGPoint? {
        for (index, island) in islands.enumerated() {
            if let seat = island.seats.firstIndex(where: { $0.id == id }) {
                return standingSpot(island: index, seat: seat)
            }
        }
        return nil
    }

    /// 行き先が変わったときだけ歩かせる。
    /// 台帳は 0.5 秒ごとに来るので、毎回指示を出し直すと歩き出せない
    private func send(_ visitor: SKNode, to target: CGPoint) {
        if let current = visitor.userData?["target"] as? NSValue,
           current.pointValue == target { return }
        if visitor.userData == nil { visitor.userData = NSMutableDictionary() }
        visitor.userData?["target"] = NSValue(point: target)

        let distance = hypot(visitor.position.x - target.x, visitor.position.y - target.y)
        visitor.removeAction(forKey: "walk")
        visitor.run(.move(to: target, duration: max(0.3, TimeInterval(distance / 70))),
                    withKey: "walk")
    }

    // MARK: - カメラ

    override func update(_ currentTime: TimeInterval) {
        // 手前のものほど後に描く。歩くたびに奥行きが変わるので毎フレーム引き直す
        for visitor in visitors.values { visitor.zPosition = -visitor.position.y }

        guard lastUpdate > 0 else {
            lastUpdate = currentTime
            switchedAt = currentTime
            return
        }
        // 止まっていた間の時間はそのまま来る。何十秒ぶんかを一度に流すと
        // 稼働の平均もカメラの寄りも一瞬で振り切れるので、1フレームぶんに丸める
        let delta = min(0.25, currentTime - lastUpdate)
        lastUpdate = currentTime

        validateLayout()
        measureActivity(by: delta)
        reconsiderFocus(at: currentTime)
        easeCamera(by: delta)
        placeMarkers()
    }

    /// 組んだときの大きさと今の大きさがずれていないか、毎フレーム確かめる。
    ///
    /// `didChangeSize` だけに任せられない。シーンが止まっている (`isPaused`) 間に
    /// パネルの大きさが変わると、描き直しも組み直しも走らないまま再開することになり、
    /// **古い座標のまま新しい大きさの部屋にカメラを合わせる**ことになる。
    /// アプリを立ち上げた直後や、他のアプリから戻ってきたときに崩れて見えるのはこれ。
    ///
    /// 見取り図の突き合わせ (`skeleton`) はここでやらない。文字列を毎フレーム
    /// 組み立てることになるので、安い比較 (大きさと列数) だけにする
    private func validateLayout() {
        guard size.height > 80 else { return }
        guard builtSkeleton == nil
                || seatColumns != builtSeatColumns
                || abs(roomWidth - builtRoom.width) > 1
                || abs(roomHeight - builtRoom.height) > 1
        else { return }
        rebuild()
    }

    /// 島ごとの稼働。動いているセッションの数をなまして持つ。
    /// 生の数で比べると、1件増減しただけでカメラが飛ぶ
    private func measureActivity(by delta: TimeInterval) {
        guard activity.count == islands.count else { return }
        let ratio = 1 - pow(0.5, delta / 4)
        for (index, island) in islands.enumerated() {
            let running = Double(island.seats.filter { $0.status == TaskStatus.running }.count)
            activity[index] += (running - activity[index]) * ratio
        }
    }

    /// カメラをどこに置くかを選び直す。
    ///
    /// **要確認が最優先。** 手を挙げている人が画面外にいる状態は、このツールの
    /// 存在意義そのものを壊すので、忙しさより先に見る。
    /// 要確認が無いときだけ、一番稼働の多い島に張り付く。
    /// 乗り換えは僅差で起こさない (`switchMargin` と `dwell` の両方を満たしたときだけ)
    private func reconsiderFocus(at now: TimeInterval) {
        if let calling = firstNeedingPerson() {
            focus = calling.point
            focusedIsland = calling.island
            switchedAt = now
            return
        }

        guard now - switchedAt >= dwell else {
            focus = hubPoint(island: min(focusedIsland, max(0, islands.count - 1)))
            return
        }
        if let busiest = activity.indices.max(by: { activity[$0] < activity[$1] }),
           busiest != focusedIsland,
           activity[busiest] > activity[focusedIsland] * switchMargin {
            focusedIsland = busiest
            switchedAt = now
        }
        focus = hubPoint(island: min(focusedIsland, max(0, islands.count - 1)))
    }

    /// 手を挙げている机のうち、一番上にあるもの。
    /// 一覧が要確認を最上部に固定しているのと同じ順序にする
    private func firstNeedingPerson() -> (island: Int, point: CGPoint)? {
        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.needsPerson {
                return (index, seatPoint(island: index, index: slot))
            }
        }
        return nil
    }

    /// 毎フレーム少しずつ寄せる。
    ///
    /// 行き先を都度 `SKAction` で指定すると、次の行き先が決まるたびに前の動きを
    /// 打ち切ることになり、カメラが小刻みに向きを変える。少しずつ寄せると
    /// 遅れて付いていく形になり、見ていて落ち着く
    private func easeCamera(by delta: TimeInterval) {
        let target = clampCamera(focus)
        // 1秒でおよそ 92% 詰める速さ。フレーム間隔に依らず同じ寄り方になる
        let ratio = 1 - pow(0.08, delta)
        eye.position = CGPoint(x: eye.position.x + (target.x - eye.position.x) * ratio,
                               y: eye.position.y + (target.y - eye.position.y) * ratio)
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

    // MARK: - 画面外の要確認

    /// 画面の外で手を挙げている机を、画面の縁の印で知らせる。
    ///
    /// カメラがそこへ着くまでのあいだ、呼ばれていること自体が見えなくなるのを防ぐ。
    /// 印はカメラの子なので、部屋がどこへ動いても画面に貼り付いたままになる
    private func placeMarkers() {
        // 毎フレーム作り直すと 60fps で SKLabelNode を作り続けることになる。
        // 印は位置が少し遅れても困らないので間引く
        guard lastUpdate - markedAt >= 0.2 else { return }
        markedAt = lastUpdate

        markers.removeAllChildren()
        let halfW = size.width / 2
        let halfH = size.height / 2
        let inset: CGFloat = 9

        var drawn = 0
        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.needsPerson {
                guard drawn < 6 else { return }
                let point = seatPoint(island: index, index: slot)
                let dx = point.x - eye.position.x
                let dy = point.y - eye.position.y
                // 画面に入っているものには印を出さない。本人が見えているのだから
                guard abs(dx) > halfW - inset || abs(dy) > halfH - inset else { continue }

                let marker = DeskScene.handMark()
                marker.position = CGPoint(
                    x: min(max(dx, -halfW + inset), halfW - inset),
                    y: min(max(dy, -halfH + inset), halfH - inset))
                marker.zPosition = 10000
                markers.addChild(marker)
                drawn += 1
            }
        }
    }

    // MARK: - クリック

    /// 机を押したらそのタブを開く。一覧の行クリックと同じ相手を呼ぶ
    override func mouseDown(with event: NSEvent) {
        let point = event.location(in: self)
        for node in nodes(at: point) {
            var current: SKNode? = node
            while let candidate = current {
                if let name = candidate.name, name.hasPrefix("seat:") {
                    onOpen?(String(name.dropFirst("seat:".count)))
                    return
                }
                current = candidate.parent
            }
        }
    }
}
