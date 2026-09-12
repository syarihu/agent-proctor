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
        DeskSKContainerView(scene: box.scene, running: running)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// SpriteKit の SKView を SwiftUI から扱い、スクロールやピンチをシーンへ届けるためのラッパー。
///
/// SwiftUI の `SpriteView` は AppKit の `scrollWheel` や `magnify` をシーンへ中継しない。
/// パンやズームの操作を `DeskScene` で受けるために、自前の `SKView` サブクラスを
/// `NSViewRepresentable` で包んで配置する
private struct DeskSKContainerView: NSViewRepresentable {
    let scene: DeskScene
    let running: Bool

    func makeNSView(context: Context) -> DeskSKView {
        let view = DeskSKView()
        view.allowsTransparency = true
        view.preferredFramesPerSecond = running ? 60 : 2
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        view.presentScene(scene)
        return view
    }

    func updateNSView(_ view: DeskSKView, context: Context) {
        view.preferredFramesPerSecond = running ? 60 : 2
        if view.scene !== scene {
            view.presentScene(scene)
        }
    }
}

/// スクロールやトラックパッドのピンチ操作を `DeskScene` に流し込む `SKView`。
///
/// マウスクリックやドラッグは標準の `SKView` が自動的にシーンの `mouseDown` や
/// `mouseDragged` に中継してくれるが、`scrollWheel` と `magnify` は
/// デフォルトでは中継されないため、ここで明示的にシーンへ渡す
private final class DeskSKView: SKView {
    override func scrollWheel(with event: NSEvent) {
        if let scene = scene as? DeskScene {
            scene.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        if let scene = scene as? DeskScene {
            scene.magnify(with: event)
        } else {
            super.magnify(with: event)
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
    /// 走っているサブエージェントの数。
    /// `agent_id` を送ってこないエージェントでは中身が空でも数だけ入る
    let subagents: Int
    /// 中身が分かるサブエージェント。分かるなら1体ずつ仕草を付けられる
    let helpers: [DeskHelper]
    /// いま触っているツール ("Edit: TaskStore.swift" など)。動いている間だけ入る。
    /// 何をしているかで仕草を変えるために使う
    let activity: String?
    /// 現在 iTerm2 で人間が見ているタブかどうか
    let isCurrent: Bool
    /// 対応するタブ番号（⌘1 など）
    let tabNumber: Int?
}

/// 机まわりの手伝い1人。台帳のサブエージェント1体に対応する
struct DeskHelper: Equatable {
    let id: String
    /// エージェント種別 ("Explore" など)
    let name: String
    /// いま触っているツール。親と同じ形式なので、同じ判定で仕草を決められる
    let activity: String?
}

/// 机の人の仕草。`activity` の頭 ("Edit: …" の Edit) から決める。
///
/// ツール名をそのまま出す代わりに、体の動きで言う。
/// 文字は小さくて読めないが、動きの違いは離れていても分かる
enum DeskGesture {
    /// 書いている (Edit / Write)
    case typing
    /// 読んでいる・探している (Read / Grep / Glob)
    case reading
    /// コマンドを回している (Bash)
    case terminal
    /// 返事を待っている (Task / WebFetch など、自分では手を動かしていないもの)
    case thinking
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

    /// セッション机の横幅。文字サイズと用紙拡大に合わせて調整
    private let deskWidth: CGFloat = 184
    /// リポジトリ (hub) の机の横幅。作業領域はいらないのでちょい大きめ
    private let hubDeskWidth: CGFloat = 104
    private let deskDepth: CGFloat = 24
    /// 机を横に何列並べるか。**最大2列にする。**
    /// 拡大した机 (184pt) と印刷用紙 (226pt) が2列並ぶのに必要な幅を基準にする
    private var seatColumns: Int {
        max(1, min(2, Int(size.width / 245)))
    }

    /// 列と列の間隔。帯の幅を使い切る
    private var columnPitch: CGFloat {
        max(242, (size.width - 24) / CGFloat(seatColumns))
    }

    /// 島1つの横幅。机の幅に、列を広げたぶんを足したもの
    private var islandWidth: CGFloat {
        deskWidth + columnPitch * CGFloat(seatColumns - 1)
    }
    /// hub (リポジトリ机) から最初のセッション机までの縦の間隔。
    /// hub は用紙が下に垂れ下がらないため、セッション間の間隔より詰めて自然な隙間にする
    private let hubRowSpacing: CGFloat = 145
    /// セッション机の段と段の縦の間隔。
    /// 上の用紙と下の吹き出しが重ならず、程よく詰まった間隔にする
    private let rowSpacing: CGFloat = 185
    /// 島と島の横の間隔。島の幅に通路を足したもの。
    /// 2列の島の間をエージェントが歩き、思考雲同士が重ならないよう 300pt 確保する
    private var islandSpacing: CGFloat { max(300, islandWidth + 110) }
    /// 部屋の左右の余白。机や思考雲が壁に密着せず、通路として歩ける幅を持たせる
    private let sideMargin: CGFloat = 180
    /// 部屋の上の余白。hub の吹き出しが奥の壁に食い込まない高さ
    private let topMargin: CGFloat = 125
    private let bottomMargin: CGFloat = 60

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
    private struct MarkerEntry {
        let node: SKNode
        let name: String
        let tabNumber: Int?
    }
    /// 表示中の画面外吹き出し。キーは "\(isDown ? "down" : "up"):\(seat.id)"
    private var activeMarkers: [String: MarkerEntry] = [:]
    /// 部屋のものを全部ぶら下げる。組み直しはこれを捨てるだけで済む
    private var room = SKNode()

    /// hub へ質問しに来ている人。席の id で引く。
    /// 机の occupant とは別のノードで、部屋の座標で歩かせる
    private var visitors: [String: SKNode] = [:]
    /// 席へ帰る途中の人。席の id で引く。
    /// 席に着くまで机の occupant を隠しておき、重なって2人に見えるのを防ぐ
    private var returning: [String: SKNode] = [:]
    /// 新しく増えた席へ向かって扉から歩いている人。席の id で引く。
    /// 着席するまで机の occupant を隠しておき、到着したら座らせる
    private var arriving: [String: SKNode] = [:]
    /// 終了して扉へ向かって歩いている人。席の id で引く。
    /// 扉から出るまで部屋の組み直しを保留し、自然な退室アニメーションを見せる
    private var departing: [String: SKNode] = [:]
    /// 扉の開閉要求カウンタ。複数人が同時に出入りしても安全に開閉を同期する
    private var openDoorCount: Int = 0

    private func requestDoorOpen() {
        openDoorCount += 1
        animateDoor(open: true)
    }

    private func requestDoorClose() {
        openDoorCount = max(0, openDoorCount - 1)
        if openDoorCount == 0 {
            animateDoor(open: false)
        }
    }
    /// 到着アニメーション待ちの席ID
    private var pendingArrivalSeats: Set<String> = []
    /// 到着アニメーション待ちのリポジトリ名
    private var pendingArrivalRepos: Set<String> = []
    /// 以前認識していた席とリポジトリの集合。増分（新規着席）の検出に使う
    private var knownSeatIds: Set<String> = []
    private var knownRepos: Set<String> = []
    private var hasInitializedArrivals = false
    /// 奥の壁の高さ。正面エントランス扉を収めるため 32pt 確保する
    private let wallHeight: CGFloat = 32
    /// 歩く速さ (pt/秒)。机を迂回して少し道程が伸びるので、直進していた頃 (70) より少し早足にしてテンポを保つ
    private let walkSpeed: CGFloat = 80
    /// 島ごとの稼働の量。いま動いているセッションの数を秒単位でならしたもの
    private var activity: [Double] = []
    /// いまカメラが張り付いている先
    private var focus: CGPoint = .zero
    private var focusedIsland = 0
    private var switchedAt: TimeInterval = 0
    private var lastUpdate: TimeInterval = 0

    /// 一度寄ったら最低これだけは留まる (秒)。
    /// これが無いと、僅差の島どうしでカメラが行ったり来たりして落ち着かない
    private let dwell: TimeInterval = 8
    /// 乗り換えに要る差。1.4 倍以上忙しくないと、カメラは動かない
    private let switchMargin: Double = 1.4

    // MARK: カメラとズーム状態

    /// 現在のカメラズーム率（1.0 が等倍、0.45 が最大拡大、2.4 が最大縮小）
    private var currentZoom: CGFloat = 1.0
    private var targetZoom: CGFloat = 1.0
    private let minZoom: CGFloat = 0.45
    private let maxZoom: CGFloat = 2.4

    /// ユーザーによる手動操作（ドラッグ移動またはスクロール/ピンチズーム）中かどうか
    private var isUserControlling = false
    private var lastUserControlTime: TimeInterval = 0
    /// 前回自動追従したアクティブタブの座標。タブが切り替わったら手動操作を解除する
    private var lastFollowedCurrentPoint: CGPoint?

    /// マウスドラッグによるパン移動の状態
    private var dragStartInWindow: CGPoint?
    private var dragStartFocus: CGPoint?
    private var isDragging = false
    private var clickedSeatId: String?

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
    /// 状態が変わるたびに部屋を作り直すと、歩いている人が毎回入口に戻ってしまう。
    /// 新しく増えた席やリポジトリを検出した場合は、正面エントランスからの入室アニメーションを走らせる
    func apply(islands: [DeskIsland]) {
        self.islands = islands

        let currentSeats = Set(islands.flatMap { $0.seats.map(\.id) })
        let currentRepos = Set(islands.map(\.repo))

        if !hasInitializedArrivals {
            knownSeatIds = currentSeats
            knownRepos = currentRepos
            hasInitializedArrivals = true
            if !rebuildIfNeeded() { refreshSeats() }
            return
        }

        let newSeats = currentSeats.subtracting(knownSeatIds)
        let newRepos = currentRepos.subtracting(knownRepos)
        let departedSeats = knownSeatIds.subtracting(currentSeats)
        let departedRepos = knownRepos.subtracting(currentRepos)

        knownSeatIds = currentSeats
        knownRepos = currentRepos

        if !newSeats.isEmpty || !newRepos.isEmpty {
            pendingArrivalSeats.formUnion(newSeats)
            pendingArrivalRepos.formUnion(newRepos)
        }

        if !departedSeats.isEmpty || !departedRepos.isEmpty {
            animateDepartures(seatIds: departedSeats, repoNames: departedRepos)
        }

        let rebuilt = rebuildIfNeeded()
        if !rebuilt {
            refreshSeats()
        }

        if !newSeats.isEmpty || !newRepos.isEmpty {
            animateArrivals(seatIds: newSeats, repoNames: newRepos)
        }
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
        // 退室中のエージェントがいる間は部屋の組み直しを保留し、扉から出るまで歩かせる
        guard departing.isEmpty else { return false }
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

    /// 横に並べる島の列数。
    /// サイドバーでの視認性と上下スクロールの操作性を保つため、島（リポジトリ）は縦1列に積む
    private var columns: Int {
        1
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
        return hubRowSpacing + rowSpacing * CGFloat(max(0, seatRows - 1)) + 190
    }

    /// 部屋の横幅。
    /// サイドバーの幅そのままにすると左右に全くパンできず、ズームアウトした時も
    /// 細長い短冊状になってしまうため、島を中央に置きつつ左右に通路の余白を十分に確保する
    private var roomWidth: CGFloat {
        let naturalWidth = islandWidth + sideMargin * 2
        return max(size.width + 300, max(580, naturalWidth))
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
        let row = index / seatColumns
        return CGPoint(x: hub.x - spread / 2 + columnPitch * CGFloat(index % seatColumns),
                       y: hub.y - hubRowSpacing - rowSpacing * CGFloat(row))
    }

    /// 机の後ろの椅子の位置（ディスプレイの目の前、座席の occupant の座標）
    private func chairSpot(island: Int, seat: Int) -> CGPoint {
        let desk = seatPoint(island: island, index: seat)
        return CGPoint(x: desk.x, y: desk.y + 30)
    }

    // MARK: - 組み立て

    private func rebuild() {
        guard size.height > 80 else { return }
        // 島が1つも無いときは hubPoint(0) を焦点に置く。部屋の左上あたりになる
        room.removeFromParent()
        room = SKNode()
        addChild(room)
        markers.removeAllChildren()
        activeMarkers.removeAll()
        visitors.removeAll()
        returning.removeAll()
        arriving.removeAll()
        departing.removeAll()
        openDoorCount = 0
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

        if isDragging {
            NSCursor.pop()
            isDragging = false
        }
        dragStartInWindow = nil
        dragStartFocus = nil
        clickedSeatId = nil

        focusedIsland = min(focusedIsland, max(0, islands.count - 1))
        focus = hubPoint(island: focusedIsland)
        eye.position = clampCamera(focus, zoom: currentZoom)
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
        let wall = SKShapeNode(rect: CGRect(x: 0, y: roomHeight - wallHeight,
                                            width: roomWidth, height: wallHeight))
        wall.fillColor = .secondaryLabelColor.withAlphaComponent(0.12)
        wall.strokeColor = .clear
        wall.zPosition = -9990
        room.addChild(wall)

        // 壁の下端の巾木（はばき）。床と壁の境界をくっきりさせる
        let baseboard = SKShapeNode(rect: CGRect(x: 0, y: roomHeight - wallHeight - 1.5,
                                                 width: roomWidth, height: 1.5))
        baseboard.fillColor = .secondaryLabelColor.withAlphaComponent(0.25)
        baseboard.strokeColor = .clear
        baseboard.zPosition = -9985
        room.addChild(baseboard)

        // 正面エントランス扉（吹き出しや中央の机に被らないよう奥壁の左上に配置）
        let door = entranceDoorNode()
        door.position = doorPosition
        room.addChild(door)
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

    /// 思い出している風の思考雲の外形パス。
    /// 喋っている吹き出しではなく、頭の中にタスク内容を思い浮かべている雲の形にする
    private func thoughtBubblePath(width: CGFloat, height: CGFloat, bulge: CGFloat = 3.2) -> CGPath {
        let path = CGMutablePath()
        let hw = width / 2
        let r = min(height / 2, 14.0)
        let left = -hw + r
        let right = hw - r
        let xLobes = 7

        path.move(to: CGPoint(x: left, y: 0))
        // 底辺（左から右へのモコモコ）
        for i in 0..<xLobes {
            let x0 = left + CGFloat(i) * (right - left) / CGFloat(xLobes)
            let x1 = left + CGFloat(i + 1) * (right - left) / CGFloat(xLobes)
            let midX = (x0 + x1) / 2
            path.addQuadCurve(to: CGPoint(x: x1, y: 0), control: CGPoint(x: midX, y: -bulge))
        }

        // 右端の丸いローブ
        path.addQuadCurve(to: CGPoint(x: hw + bulge * 0.8, y: height / 2),
                          control: CGPoint(x: hw + bulge * 0.5, y: -bulge * 0.5))
        path.addQuadCurve(to: CGPoint(x: right, y: height),
                          control: CGPoint(x: hw + bulge * 0.5, y: height + bulge * 0.5))

        // 上辺（右から左へのモコモコ）
        for i in 0..<xLobes {
            let x0 = right - CGFloat(i) * (right - left) / CGFloat(xLobes)
            let x1 = right - CGFloat(i + 1) * (right - left) / CGFloat(xLobes)
            let midX = (x0 + x1) / 2
            path.addQuadCurve(to: CGPoint(x: x1, y: height), control: CGPoint(x: midX, y: height + bulge))
        }

        // 左端の丸いローブ
        path.addQuadCurve(to: CGPoint(x: -hw - bulge * 0.8, y: height / 2),
                          control: CGPoint(x: -hw - bulge * 0.5, y: height + bulge * 0.5))
        path.addQuadCurve(to: CGPoint(x: left, y: 0),
                          control: CGPoint(x: -hw - bulge * 0.5, y: -bulge * 0.5))

        path.closeSubpath()
        return path
    }

    /// 頭上に浮かべる思考雲（タスク内容またはリポジトリ名を表示する）
    private func speechBubbleNode(isHub: Bool, initialText: String) -> SKNode {
        let node = SKNode()
        node.name = "speechBubble"

        let width: CGFloat = isHub ? 210 : 222
        let height: CGFloat = isHub ? 34 : 28
        let fontSize: CGFloat = isHub ? 13.2 : 11.3
        let limit = isHub ? 22 : 30
        let bubbleY: CGFloat = 70

        let shapePath = thoughtBubblePath(width: width, height: height, bulge: isHub ? 3.4 : 3.0)
        let shape = SKShapeNode(path: shapePath)
        shape.name = "bubbleShape"
        shape.position = CGPoint(x: 0, y: bubbleY)
        shape.fillColor = DeskScene.bubbleFillColor(isHub: isHub, isCurrent: false)
        shape.strokeColor = isHub
            ? .secondaryLabelColor.withAlphaComponent(0.55)
            : .secondaryLabelColor.withAlphaComponent(0.35)
        shape.lineWidth = isHub ? 1.0 : 0.8
        node.addChild(shape)

        // 思い出している風のしっぽ（頭の横から右上方向へ連なる小さな思考の泡）
        let dots: [(CGFloat, CGFloat, CGFloat)] = [
            (11.0, -11.0, 1.3),
            (16.5, -6.8, 1.9),
            (23.0, -2.8, 2.7)
        ]
        for (i, (dx, dy, r)) in dots.enumerated() {
            let dot = SKShapeNode(circleOfRadius: r)
            dot.name = "trailDot\(i)"
            dot.position = CGPoint(x: dx, y: bubbleY + dy)
            dot.fillColor = shape.fillColor
            dot.strokeColor = shape.strokeColor
            dot.lineWidth = shape.lineWidth
            node.addChild(dot)
        }

        let label = SKLabelNode(fontNamed: "SFMono-Bold")
        label.name = "bubbleLabel"
        label.fontSize = fontSize
        label.fontColor = .labelColor
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: bubbleY + height / 2)
        label.text = truncateScreenText(initialText, limit: limit)
        node.addChild(label)

        if !isHub {
            // タブ番号バッジ（⌘1など）。思考雲の左上角に乗せる
            let badge = SKNode()
            badge.name = "tabBadge"
            badge.position = CGPoint(x: -width / 2 + 18, y: bubbleY + height - 1)
            badge.zPosition = 10
            badge.isHidden = true

            let colors = DeskScene.tabBadgeColors(isCurrent: false)
            let badgeBg = SKShapeNode(rect: CGRect(x: -13, y: -7, width: 26, height: 14),
                                      cornerRadius: 3.5)
            badgeBg.name = "tabBadgeBg"
            badgeBg.fillColor = colors.bg
            badgeBg.strokeColor = colors.stroke
            badgeBg.lineWidth = colors.width
            badge.addChild(badgeBg)

            let badgeLabel = SKLabelNode(fontNamed: "SFMono-Bold")
            badgeLabel.name = "tabBadgeLabel"
            badgeLabel.fontSize = 8.5
            badgeLabel.fontColor = colors.text
            badgeLabel.horizontalAlignmentMode = .center
            badgeLabel.verticalAlignmentMode = .center
            badgeLabel.position = CGPoint(x: 0, y: 0)
            badge.addChild(badgeLabel)

            node.addChild(badge)
        }

        // 吹き出しは頭上に浮かぶ要素のため、床を歩く人間や机よりも必ず手前に描画する。
        // 人間が吹き出しの下を歩く際も、吹き出しの文字や枠が隠れずに人間が吹き出しの裏を通るよう、
        // 机や歩行ノード（zPosition <= 0）より十分に高い zPosition を設定する
        node.zPosition = 5000
        return node
    }

    /// 思考雲の背景色。
    /// 人間が見ているタブ（isCurrent）は、ステータス枠線を保ちつつ
    /// 雲の中身がふわっと明るく点灯したようなハイライト色にする
    private static func bubbleFillColor(isHub: Bool, isCurrent: Bool) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            if isCurrent {
                return isDark
                    ? NSColor(red: 0.20, green: 0.28, blue: 0.40, alpha: 0.98)
                    : NSColor(red: 0.88, green: 0.93, blue: 0.98, alpha: 0.98)
            } else if isHub {
                return isDark
                    ? NSColor(red: 0.18, green: 0.22, blue: 0.30, alpha: 0.96)
                    : NSColor(red: 0.95, green: 0.96, blue: 0.98, alpha: 0.96)
            } else {
                return isDark
                    ? NSColor(red: 0.14, green: 0.18, blue: 0.25, alpha: 0.96)
                    : NSColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 0.96)
            }
        }
    }

    /// タブ番号バッジの色。
    /// アクティブ時は鮮やかな水色で点灯し、非アクティブ時は控えめなグレーで常時表示する
    private static func tabBadgeColors(isCurrent: Bool) -> (bg: NSColor, stroke: NSColor, text: NSColor, width: CGFloat) {
        if isCurrent {
            return (
                bg: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(red: 0.12, green: 0.20, blue: 0.30, alpha: 0.98)
                        : NSColor(red: 0.92, green: 0.96, blue: 1.0, alpha: 0.98)
                },
                stroke: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.90)
                        : NSColor(red: 0.100, green: 0.500, blue: 0.850, alpha: 0.80)
                },
                text: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 1.0)
                        : NSColor(red: 0.05, green: 0.40, blue: 0.75, alpha: 1.0)
                },
                width: 1.0
            )
        } else {
            return (
                bg: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 0.95)
                        : NSColor(white: 0.93, alpha: 0.95)
                },
                stroke: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.45, alpha: 0.40)
                        : NSColor(white: 0.65, alpha: 0.50)
                },
                text: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.65, alpha: 0.75)
                        : NSColor(white: 0.40, alpha: 0.80)
                },
                width: 0.7
            )
        }
    }

    /// 机の下に垂れ下がる連続帳票・プリント用紙。作業ログを3行印刷する
    private func printedPaperNode(width: CGFloat = 226, height: CGFloat = 60) -> SKNode {
        let paper = SKNode()
        paper.name = "printedPaper"
        let hw = width / 2
        let topY: CGFloat = -deskDepth / 2 - 4
        let bottomY = topY - height

        // 帳票用紙のベース背景
        let bg = SKShapeNode(rect: CGRect(x: -hw, y: bottomY, width: width, height: height),
                             cornerRadius: 2.5)
        bg.name = "paperBg"
        bg.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 0.96)
                : NSColor(red: 0.96, green: 0.96, blue: 0.93, alpha: 0.96)
        }
        bg.strokeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.35, alpha: 0.6)
                : NSColor(white: 0.75, alpha: 0.8)
        }
        bg.lineWidth = 0.8
        paper.addChild(bg)

        // ドットインパクト・連続帳票の送り穴（スプロケットホール）を左右に3つずつ配置
        let holeRadius: CGFloat = 1.5
        let leftHoleX = -hw + 5.0
        let rightHoleX = hw - 5.0
        for i in 0..<3 {
            let holeY = topY - 9.0 - CGFloat(i) * 19.0
            for x in [leftHoleX, rightHoleX] {
                let hole = SKShapeNode(circleOfRadius: holeRadius)
                hole.position = CGPoint(x: x, y: holeY)
                hole.fillColor = NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 0.9)
                        : NSColor(white: 0.80, alpha: 0.9)
                }
                hole.strokeColor = .clear
                paper.addChild(hole)
            }
        }

        // 帳票用紙の中央段ゼブラ帯（グリーンバー風の薄い帯）
        let stripe = SKShapeNode(rect: CGRect(x: -hw + 9.5, y: topY - 37.5, width: width - 19.0, height: 19.0))
        stripe.fillColor = NSColor(red: 0.2, green: 0.6, blue: 0.35, alpha: 0.06)
        stripe.strokeColor = .clear
        paper.addChild(stripe)

        // 下端のミシン目（切り取り破線）
        let perfPath = CGMutablePath()
        let perfY = bottomY + 2.5
        let perfStart = -hw + 9.0
        let perfEnd = hw - 9.0
        var px = perfStart
        while px < perfEnd {
            perfPath.move(to: CGPoint(x: px, y: perfY))
            perfPath.addLine(to: CGPoint(x: min(px + 2.8, perfEnd), y: perfY))
            px += 5.0
        }
        let perf = SKShapeNode(path: perfPath)
        perf.strokeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.45, alpha: 0.45)
                : NSColor(white: 0.65, alpha: 0.55)
        }
        perf.lineWidth = 0.6
        paper.addChild(perf)

        // 印刷された作業ログ3行
        let textLeft = -hw + 14.0
        for lineIndex in 0..<3 {
            let label = SKLabelNode(fontNamed: "SFMono-Bold")
            label.name = "paperLine\(lineIndex)"
            label.fontSize = 9.8
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: textLeft, y: topY - 9.0 - CGFloat(lineIndex) * 19.0)
            label.zPosition = 2
            label.fontColor = .clear
            paper.addChild(label)
        }

        paper.zPosition = 10
        return paper
    }

    /// 机1つ。天板 (明るい) と前面 (暗い) の2枚で厚みを出し、奥に小型モニタを置く。
    /// 頭上にはタスク内容の吹き出し、机の下には作業ログが印刷された帳票用紙が垂れ下がる
    private func deskNode(at point: CGPoint, label: String,
                          isHub: Bool, seat: DeskSeat?) -> SKNode {
        let node = SKNode()
        node.position = point
        // 手前のものほど後に描く。人が机の前に立ったときに正しく重なる
        node.zPosition = -point.y
        // クリックの当たり判定はこの名前で引く。hub には開く相手がいない
        if let seat {
            node.name = "seat:\(seat.id)"
        } else {
            node.name = "hub:\(label)"
        }

        // セッション机は横2倍 (184pt)、hub は作業領域不要でちょい大きめ (104pt)
        let width = isHub ? hubDeskWidth : deskWidth

        let front = SKShapeNode(rect: CGRect(x: -width / 2, y: -deskDepth / 2 - 9,
                                             width: width, height: 10),
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

        // 机の上のモニタ（セッションは横2倍の108pt、hubは52pt、文字表示なし）
        let mWidth: CGFloat = isHub ? 52 : 108
        let mHeight: CGFloat = isHub ? 22 : 28
        let screenY: CGFloat = 9

        let stand = SKShapeNode(rect: CGRect(x: -mWidth / 6, y: screenY - 3, width: mWidth / 3, height: 5),
                                cornerRadius: 1.5)
        stand.fillColor = .secondaryLabelColor.withAlphaComponent(0.35)
        stand.strokeColor = .clear
        stand.zPosition = -1
        node.addChild(stand)

        let screen = SKShapeNode(rect: CGRect(x: -mWidth / 2, y: screenY,
                                              width: mWidth, height: mHeight),
                                 cornerRadius: 2.5)
        screen.name = "screen"
        screen.fillColor = .secondaryLabelColor.withAlphaComponent(0.25)
        screen.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        screen.lineWidth = 1.0
        node.addChild(screen)

        // 書類の山を載せる器（天板の両端）
        for (name, side) in [("stackL", -1.0), ("stackR", 1.0)] as [(String, CGFloat)] {
            let stack = SKNode()
            stack.name = name
            stack.position = CGPoint(x: side * (width / 2 - 11), y: -6)
            stack.zPosition = 3
            node.addChild(stack)
        }

        // 席の人。1.2倍サイズにする
        let occupant = person(tint: isHub ? .labelColor : .labelColor)
        occupant.name = "occupant"
        occupant.setScale(1.2)
        occupant.position = CGPoint(x: 0, y: 30)
        occupant.zPosition = -20
        if isHub && pendingArrivalRepos.contains(label) {
            occupant.isHidden = true
        }
        node.addChild(occupant)

        // 頭上の吹き出し（hub は大きめ、セッションは横2倍でタスク内容を広く表示）
        let bubble = speechBubbleNode(isHub: isHub, initialText: label)
        node.addChild(bubble)

        if seat != nil {
            // 机の下に垂れ下がる連続帳票・プリント用紙（横2倍で作業ログ3行）
            let paper = printedPaperNode(width: 226, height: 60)
            node.addChild(paper)

            // 挙げた手。ディスプレイの右横（他のコンテンツに被らない位置）に配置
            let hand = DeskScene.handMark()
            hand.name = "hand"
            hand.position = CGPoint(x: mWidth / 2 + 13, y: screenY + 4)
            hand.zPosition = 25
            hand.isHidden = true
            node.addChild(hand)
        }

        return node
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
        node.anchorPoint = CGPoint(x: 0.5, y: 0.1)
        return node
    }

    /// ツール名から仕草を決める。
    ///
    /// 知らないツールは書いていることにする。一番多いのがそれで、
    /// 外したときの見え方も一番おとなしい
    private func gesture(for activity: String?) -> DeskGesture {
        let tool = activity?.split(separator: ":").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch tool {
        case "Read", "Grep", "Glob", "LS", "NotebookRead", "Explore",
             "view_file", "grep_search", "find_by_name", "list_dir", "search_web", "read_url_content", "WebSearch":
            return .reading
        case "Bash", "BashOutput", "KillShell", "KillBash", "run_command":
            return .terminal
        case "Task", "Agent", "WebFetch", "SendMessage", "invoke_subagent":
            return .thinking
        default:
            return .typing
        }
    }

    /// 画面幅に収まるよう文字数を切り詰める。
    /// 収める先が吹き出しと帳票の各行で違い、共通の既定値を置くと
    /// どちらかが必ずはみ出すので、上限は呼ぶ側に必ず書かせる
    private func truncateScreenText(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    // 帳票に刷る文字の色。
    //
    // 机1つにつき更新のたび引くので、その場で作らず使い回す。
    // NSColor(name:) の動的プロバイダは配色の切り替えを自分で追うため、
    // 1度作れば明暗どちらでも正しい色を返す
    private static let logGreen = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.98, blue: 0.50, alpha: 0.95)
            : NSColor(red: 0.12, green: 0.55, blue: 0.22, alpha: 1.0)
    }
    private static let logCyan = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.40, green: 0.90, blue: 1.0, alpha: 0.95)
            : NSColor(red: 0.05, green: 0.45, blue: 0.75, alpha: 1.0)
    }
    private static let logYellow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.85, blue: 0.40, alpha: 0.95)
            : NSColor(red: 0.70, green: 0.45, blue: 0.05, alpha: 1.0)
    }
    private static let logOrange = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 0.95)
            : NSColor(red: 0.80, green: 0.35, blue: 0.05, alpha: 1.0)
    }
    private static let logRed = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 0.95)
            : NSColor(red: 0.78, green: 0.15, blue: 0.15, alpha: 1.0)
    }
    private static let logDim = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.70, alpha: 0.85)
            : NSColor(white: 0.35, alpha: 0.9)
    }

    // 正面エントランス扉の配色。壁と同じく動的プロバイダで明暗両対応にする
    private static let doorFrameColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.28, alpha: 0.95)
            : NSColor(white: 0.68, alpha: 0.95)
    }
    private static let doorOpeningColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.92, green: 0.85, blue: 0.65, alpha: 0.35)
            : NSColor(red: 0.98, green: 0.94, blue: 0.82, alpha: 0.90)
    }
    private static let doorLeafColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.16, alpha: 0.95)
            : NSColor(white: 0.92, alpha: 0.98)
    }
    private static let doorMatColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.22, alpha: 0.60)
            : NSColor(white: 0.82, alpha: 0.70)
    }

    /// 連続帳票用紙に印刷する作業ログ行（3行）。
    ///
    /// 出る先はモニタではなく机の下に垂れる用紙なので、行数は用紙の段数 (3) に合わせる。
    /// ここを増やしても用紙には刷られない
    private func printedLogLines(seat: DeskSeat) -> [(text: String, color: NSColor)] {
        let green = DeskScene.logGreen
        let cyan = DeskScene.logCyan
        let yellow = DeskScene.logYellow
        let orange = DeskScene.logOrange
        let red = DeskScene.logRed
        let dim = DeskScene.logDim

        switch seat.status {
        case TaskStatus.running:
            let raw = seat.activity
                ?? seat.helpers.first(where: { $0.activity != nil })?.activity.map { "sub: \($0)" }

            if let raw, !raw.isEmpty {
                let isSub = raw.hasPrefix("sub: ")
                let target = isSub ? String(raw.dropFirst(5)) : raw
                let parts = target.split(separator: ":", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                let tool = parts.first ?? ""
                let detail = parts.count > 1 ? parts[1] : ""
                let file = (detail as NSString).lastPathComponent

                switch tool {
                case "Read", "NotebookRead", "view_file":
                    return [
                        ("🔍 \(truncateScreenText(file, limit: 28))", cyan),
                        ("import Foundation", dim),
                        ("func execute() { ... }", dim),
                    ]
                case "Grep", "grep_search", "Glob", "find_by_name":
                    return [
                        ("🔍 \(tool): \(truncateScreenText(detail, limit: 22))", cyan),
                        ("> scanning files...", yellow),
                        ("matches found: 3", dim),
                    ]
                case "Edit", "write_to_file", "replace_file_content":
                    return [
                        ("✏️ \(truncateScreenText(file, limit: 28))", yellow),
                        ("@@ -120,6 +120,8 @@", dim),
                        ("+ updating display", green),
                    ]
                case "Bash", "BashOutput", "KillShell", "KillBash", "run_command":
                    let subPrefix = isSub ? "sub " : ""
                    return [
                        ("$ \(truncateScreenText(subPrefix + detail, limit: 28))", green),
                        ("> running process...", dim),
                        ("PID \(seat.id.hashValue & 0x7fff) █", green),
                    ]
                case "search_web", "WebSearch":
                    return [
                        ("🌐 \(truncateScreenText(detail, limit: 28))", cyan),
                        ("> querying web...", dim),
                        ("status: 200 OK █", green),
                    ]
                default:
                    let subPrefix = isSub ? "sub " : ""
                    return [
                        ("$ \(truncateScreenText(subPrefix + raw, limit: 28))", green),
                        ("> working on task...", dim),
                        ("status: active █", cyan),
                    ]
                }
            } else {
                return [
                    ("$ \(truncateScreenText(seat.name, limit: 28))", green),
                    ("> agent working...", cyan),
                    ("status: running █", green),
                ]
            }

        case TaskStatus.waiting:
            let req = seat.helpers.first(where: { $0.activity != nil })?.activity
                ?? seat.activity
                ?? "approval"
            return [
                ("⚠️ WAITING APPROVAL", orange),
                ("> \(truncateScreenText(req, limit: 28))", yellow),
                ("[ Confirm / Deny ] █", orange),
            ]

        case TaskStatus.done:
            return [
                ("✓ TASK COMPLETED", green),
                ("> \(truncateScreenText(seat.name, limit: 28))", dim),
                ("all done. 0 errors.", green),
            ]

        case TaskStatus.failed:
            return [
                ("✕ TASK FAILED", red),
                ("> exit code: 1", red),
                ("check log for details", dim),
            ]

        case TaskStatus.seen:
            return [
                ("✓ \(truncateScreenText(seat.name, limit: 28))", dim),
                ("reviewed.", dim),
                ("$ _", dim),
            ]

        default:
            return [
                ("proctor terminal", dim),
                ("ready.", dim),
                ("$ _", dim),
            ]
        }
    }

    /// 机まわりのサブエージェント。
    ///
    /// 一覧では机の下に小さく畳むしかないが、俯瞰なら人を増やすだけで
    /// 「この机は何人がかりで動いている」が一目で分かる。ここは俯瞰の独壇場
    private func setHelpers(_ desk: SKNode, helpers: [DeskHelper], count: Int, tint: NSColor) {
        // 4人まで。机の左右に振り分けて、足りなければ後ろの段へ回す。
        // それ以上出しても、机の間隔 (列の間隔は最小 120pt) に収まらない。
        //
        // 数と中身の両方を見るのは、`agent_id` を送ってこないエージェントがいるため。
        // そちらでは中身が空のまま数だけ入るので、数を捨てると手伝いが消える
        let shown = min(4, max(count, helpers.count))
        let scale: CGFloat = 0.94

        for index in 0..<4 {
            let name = "helper\(index)"
            guard index < shown else {
                desk.childNode(withName: name)?.removeFromParent()
                continue
            }

            let helper: SKNode
            let side: CGFloat = index % 2 == 0 ? -1 : 1
            let home = CGPoint(x: side * (deskWidth / 2 + 16),
                               y: index < 2 ? 4 : 28)
            if let existing = desk.childNode(withName: name) {
                helper = existing
                helper.position = home
            } else {
                helper = person(tint: tint)
                helper.name = name
                helper.position = home
                helper.zPosition = 10
                helper.alpha = 0.8
                desk.addChild(helper)
            }

            // 中身が分かるぶんは、その子が触っているツールで仕草を決める。
            // 分からないぶん (数だけのもの) は待っていることにする——
            // 何をしているか言えないのに手を動かして見せると、嘘をつくことになる
            let move = index < helpers.count
                ? gesture(for: helpers[index].activity)
                : DeskGesture.thinking
            act(helper, gesture: move, scale: scale)
        }
    }

    /// 席の人に仕草をさせる。
    ///
    /// 動きの向きと速さで、何をしているかを言う。
    /// 打鍵は細かい上下、調べる・探すのは覗き込みながらキョロキョロ見比べる動き、
    /// 端末は待ちが混じるので時々うなずく、返事待ちは呼吸だけ
    private func act(_ occupant: SKNode, gesture: DeskGesture, scale: CGFloat = 1.2) {
        occupant.removeAction(forKey: "gesture")
        occupant.zRotation = 0
        // 手伝いは縮めて立っているので、素の 1 に戻さず元の縮尺へ戻す
        occupant.setScale(scale)

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
        occupant.run(.repeatForever(motion), withKey: "gesture")

        // 調べる・探すときは手元に虫眼鏡（ルーペ）を持たせる。
        // 覗き込む動きと道具の両方で「探している」ことを一目で伝える
        let loupe = occupant.childNode(withName: "loupe") ?? occupant.childNode(withName: "sheet")
        if gesture == .reading {
            guard loupe == nil else { return }
            let tool = magnifyingGlass()
            tool.name = "loupe"
            tool.position = CGPoint(x: 6, y: 6)
            tool.zPosition = 25
            occupant.addChild(tool)
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

    /// 調べる・探すときに手に持つ虫眼鏡（ルーペ）。
    /// 文字は読めなくても、ルーペを持って覗き込む姿で「調べている」ことが一目で分かる
    private func magnifyingGlass() -> SKNode {
        let loupe = SKNode()

        // 持ち手（柄）。(0, 0) を握り手（ピボット）にして、右上に向かってレンズを伸ばす
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

        // レンズのガラス反射（光の反射ハイライト）
        let glint = SKShapeNode(circleOfRadius: 0.9)
        glint.position = CGPoint(x: -8.2, y: 8.2)
        glint.fillColor = .white.withAlphaComponent(0.85)
        glint.strokeColor = .clear
        loupe.addChild(glint)

        return loupe
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
        let move = gesture(for: seat.activity)
        let crew = seat.helpers.map { "\($0.id):\($0.activity ?? "-")" }.joined(separator: ",")
        let isAway = visitors[seat.id] != nil
            || returning[seat.id] != nil
            || arriving[seat.id] != nil
            || departing[seat.id] != nil
            || pendingArrivalSeats.contains(seat.id)
        let signature = """
            \(seat.status)/\(seat.needsPerson)/\(seat.subagents)/\(move)/\(crew)/\(isAway)/\(seat.activity ?? "-")/\(seat.isCurrent)/\(seat.tabNumber ?? -1)
            """
        if desk.userData == nil { desk.userData = NSMutableDictionary() }
        let unchanged = desk.userData?["dressed"] as? String == signature

        // 書類の山だけは別に見る。積み直すたびに1枚ずつのばらつきを振り直すので、
        // 使用量が動いていないのに積み直すと紙がチラつく。
        // 逆に手伝いのツールは頻繁に変わるので、山と同じ条件にはできない
        let stacked = desk.userData?["stacked"] as? Int
        if stacked != seat.contextPercent {
            desk.userData?["stacked"] = seat.contextPercent ?? 0
            restack(desk, percent: seat.contextPercent ?? 0)
        }
        if unchanged { return }
        desk.userData?["dressed"] = signature

        let screen = desk.childNode(withName: "screen") as? SKShapeNode
        let occupant = desk.childNode(withName: "occupant")
        let hand = desk.childNode(withName: "hand")
        let bubble = desk.childNode(withName: "speechBubble")
        let bubbleShape = bubble?.childNode(withName: "bubbleShape") as? SKShapeNode
        let bubbleLabel = bubble?.childNode(withName: "bubbleLabel") as? SKLabelNode
        let paper = desk.childNode(withName: "printedPaper")

        let isMissing = seat.status == TaskStatus.missing
        bubble?.isHidden = isMissing
        paper?.isHidden = isMissing
        if !isMissing {
            bubbleLabel?.text = truncateScreenText(seat.name, limit: 30)
        }

        // 席に人がいるかどうか。
        //
        // 動いていた場所が消えたもの (missing) だけ席を空ける。
        // セッション開始直後の待機中 (idle) も、扉から入ってきて席に座り指示を待つ。
        // 質問で行列に並んでいる最中 (waiting) や、移動中 (isAway) は席を離れる
        let seated = !isMissing
            && seat.status != TaskStatus.waiting
            && !isAway
        occupant?.isHidden = !seated
        if seated { occupant?.setScale(1.2) }

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

        occupant?.removeAction(forKey: "gesture")
        occupant?.zRotation = 0
        occupant?.childNode(withName: "sheet")?.removeFromParent()
        occupant?.childNode(withName: "loupe")?.removeFromParent()
        occupant?.alpha = 1

        // 手伝いが出るのは動いている間と確認待ちの間だけ。完了や失敗の机に
        // 人だけ残ると、まだ動いているように見える。
        // 承認待ちの間も子エージェントは稼働中なので表示を維持する
        let working = seat.status == TaskStatus.running || seat.status == TaskStatus.waiting
        setHelpers(desk,
                   helpers: working ? seat.helpers : [],
                   count: working ? seat.subagents : 0,
                   tint: .labelColor)
        // 座っているときは机の奥。立っているときは机の手前なので、重なりも入れ替える
        occupant?.position = CGPoint(x: 0, y: 30)
        occupant?.zPosition = -20

        // 連続帳票用紙に作業ログ3行を印刷する
        let termLines = printedLogLines(seat: seat)
        for lineIndex in 0..<3 {
            let label = paper?.childNode(withName: "paperLine\(lineIndex)") as? SKLabelNode
            if lineIndex < termLines.count {
                label?.text = termLines[lineIndex].text
                label?.fontColor = termLines[lineIndex].color
            } else {
                label?.text = nil
                label?.fontColor = .clear
            }
        }

        // 思考雲の背景色（人間が見ているタブなら明るいアクティブ色）
        let bubbleFill = DeskScene.bubbleFillColor(isHub: false, isCurrent: seat.isCurrent)
        bubbleShape?.fillColor = bubbleFill
        for i in 0..<3 {
            let dot = bubble?.childNode(withName: "trailDot\(i)") as? SKShapeNode
            dot?.fillColor = bubbleFill
        }

        func setBubbleColor(stroke: NSColor, width: CGFloat) {
            let activeBonus: CGFloat = seat.isCurrent ? 0.35 : 0.0
            bubbleShape?.strokeColor = stroke
            bubbleShape?.lineWidth = width + activeBonus
            for i in 0..<3 {
                let dot = bubble?.childNode(withName: "trailDot\(i)") as? SKShapeNode
                dot?.strokeColor = stroke
                dot?.lineWidth = width + activeBonus
            }
        }

        switch seat.status {
        case TaskStatus.running:
            screen?.fillColor = NSColor(red: 0.06, green: 0.10, blue: 0.17, alpha: 0.95)
            screen?.strokeColor = NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.85)
            setBubbleColor(stroke: NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.9), width: 1.0)
            if let occupant { act(occupant, gesture: move) }
        case TaskStatus.waiting:
            screen?.fillColor = NSColor(red: 0.18, green: 0.11, blue: 0.04, alpha: 0.95)
            screen?.strokeColor = NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.9)
            setBubbleColor(stroke: NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.95), width: 1.2)
        case TaskStatus.done:
            screen?.fillColor = NSColor(red: 0.04, green: 0.14, blue: 0.07, alpha: 0.95)
            screen?.strokeColor = NSColor(red: 0.400, green: 0.733, blue: 0.416, alpha: 0.85)
            setBubbleColor(stroke: NSColor(red: 0.400, green: 0.733, blue: 0.416, alpha: 0.85), width: 1.0)
        case TaskStatus.failed:
            screen?.fillColor = NSColor(red: 0.16, green: 0.04, blue: 0.04, alpha: 0.95)
            screen?.strokeColor = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 0.85)
            setBubbleColor(stroke: NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 0.85), width: 1.0)
        case TaskStatus.seen:
            screen?.fillColor = .secondaryLabelColor.withAlphaComponent(0.20)
            screen?.strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
            setBubbleColor(stroke: .secondaryLabelColor.withAlphaComponent(0.35), width: 0.8)
            occupant?.alpha = 0.5
        default:
            screen?.fillColor = .secondaryLabelColor.withAlphaComponent(0.20)
            screen?.strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
            setBubbleColor(stroke: .secondaryLabelColor.withAlphaComponent(0.35), width: 0.8)
        }

        desk.alpha = seat.status == TaskStatus.missing ? 0.45 : 1

        // 思考雲の左上にタブ番号バッジ（⌘1など）を出す（非アクティブ時も控えめな色で常時表示）
        let tabBadge = bubble?.childNode(withName: "tabBadge")
        let tabBadgeBg = tabBadge?.childNode(withName: "tabBadgeBg") as? SKShapeNode
        let tabBadgeLabel = tabBadge?.childNode(withName: "tabBadgeLabel") as? SKLabelNode
        if let num = seat.tabNumber, num <= 9 {
            tabBadgeLabel?.text = "⌘\(num)"
            let colors = DeskScene.tabBadgeColors(isCurrent: seat.isCurrent)
            tabBadgeBg?.fillColor = colors.bg
            tabBadgeBg?.strokeColor = colors.stroke
            tabBadgeBg?.lineWidth = colors.width
            tabBadgeLabel?.fontColor = colors.text
            tabBadge?.isHidden = false
        } else {
            tabBadge?.isHidden = true
        }
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

    /// hub の机の前の待機列の位置。
    ///
    /// 机の手前（正面）に対面するように縦1列で並ばせる。
    /// 先頭（slot 0）は机の真正面でハブ担当者と対面し、2人目以降はその後ろへ並ぶ
    private func queuePoint(island: Int, slot: Int) -> CGPoint {
        let hub = hubPoint(island: island)
        return CGPoint(x: hub.x,
                       y: hub.y - 38 - CGFloat(slot) * 24)
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
            } else if let returningVisitor = returning.removeValue(forKey: seat.id) {
                // 席へ帰る途中で再び待ち状態になった。帰り道を打ち切って列へ向かわせる
                visitor = returningVisitor
                visitors[seat.id] = visitor
            } else {
                // 席から立ち上がったところから歩き出す。人間は1.2倍サイズ
                visitor = person(tint: .labelColor)
                visitor.setScale(1.2)
                visitor.position = chairSpot(island: index, seat: seatIndex)
                room.addChild(visitor)
                visitors[seat.id] = visitor
            }
            send(visitor, to: target, island: index, seatIndex: seatIndex)
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
            returning[id] = visitor
            visitor.userData?.removeObject(forKey: "target")
            visitor.removeAction(forKey: "walk")

            let points = waypoints(from: visitor.position, to: home.spot, island: home.island, seatIndex: home.seat)
            var actions: [SKAction] = []
            var from = visitor.position
            for pt in points {
                let distance = hypot(pt.x - from.x, pt.y - from.y)
                guard distance > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(distance / walkSpeed))))
                from = pt
            }
            actions.append(.run { [weak self, weak visitor] in
                visitor?.removeFromParent()
                self?.returning.removeValue(forKey: id)
                self?.refreshSeatOccupant(id: id)
            })
            visitor.run(.sequence(actions), withKey: "walk")
        }
    }

    /// 席に戻ったタイミングで座っている人を出し直す。
    /// 戻り着く前に出してしまうと席に2人いるように見えるため、到着を待って戻す
    private func refreshSeatOccupant(id: String) {
        guard let desk = room.childNode(withName: "seat:\(id)") else { return }
        for island in islands {
            if let seat = island.seats.first(where: { $0.id == id }) {
                let seated = seat.status != TaskStatus.missing
                    && seat.status != TaskStatus.waiting
                    && returning[id] == nil
                    && arriving[id] == nil
                    && !pendingArrivalSeats.contains(id)
                let occupant = desk.childNode(withName: "occupant")
                occupant?.isHidden = !seated
                if seated { occupant?.setScale(1.2) }
                return
            }
        }
    }

    /// 席へ帰る先。机がもう無ければ nil
    private func homeSpot(of id: String) -> (island: Int, seat: Int, spot: CGPoint)? {
        for (index, island) in islands.enumerated() {
            if let seat = island.seats.firstIndex(where: { $0.id == id }) {
                return (index, seat, chairSpot(island: index, seat: seat))
            }
        }
        return nil
    }

    /// 机や人を避けて歩くための経由地を求める。
    ///
    /// 吹き出しは頭上に浮いているため障害物として扱わず直進を許容するが、
    /// 物理的な机やモニタは通り抜けず通路を回る。
    /// hub 机の手前に対面で並ぶ待機列への最短で自然な動線を通す
    private func waypoints(from start: CGPoint, to target: CGPoint, island: Int, seatIndex: Int) -> [CGPoint] {
        guard hypot(start.x - target.x, start.y - target.y) >= 2 else { return [] }

        // すでに同じ高さにいるなら直線で歩ける (同じ段の通路など)
        if abs(start.y - target.y) < 4 {
            return [target]
        }

        let hub = hubPoint(island: island)

        // 待機列内での前後移動（どちらもハブ机の手前エリアにいる）
        if abs(start.x - target.x) < 4 && start.y >= hub.y - 120 && target.y >= hub.y - 120 {
            return [target]
        }

        let row = seatIndex / seatColumns

        // 最上段（Row 0）の席とハブ机の間には物理的な机が存在しない。
        // 頭上の吹き出しは障害物ではないため、迂回せず正面の待機列へ直線で歩かせる
        if row == 0 && seatColumns == 1 {
            return [target]
        }

        let isGoingToQueue = target.y > start.y

        if seatColumns > 1 {
            // 2列配置のときは机と机の間の中央通路 (x = hub.x) を通る
            let centerAisleX = hub.x
            var points: [CGPoint] = []
            if isGoingToQueue {
                if abs(start.x - centerAisleX) >= 4 {
                    points.append(CGPoint(x: centerAisleX, y: start.y))
                }
                points.append(target)
            } else {
                if abs(centerAisleX - target.x) >= 4 {
                    points.append(CGPoint(x: centerAisleX, y: target.y))
                }
                points.append(target)
            }
            return points
        } else {
            // 1列配置で Row 1 以降の席は、上の机を回り込むため机の外側の側道を通る
            let aisleX = hub.x - (deskWidth / 2 + 14)
            var points: [CGPoint] = []
            if abs(start.x - aisleX) >= 4 {
                points.append(CGPoint(x: aisleX, y: start.y))
            }
            points.append(CGPoint(x: aisleX, y: target.y))
            if abs(aisleX - target.x) >= 4 {
                points.append(target)
            }
            return points
        }
    }

    /// 行き先が変わったときだけ歩かせる。
    /// 台帳は 0.5 秒ごとに来るので、毎回指示を出し直すと歩き出せない
    private func send(_ visitor: SKNode, to target: CGPoint, island: Int, seatIndex: Int) {
        if let current = visitor.userData?["target"] as? NSValue,
           current.pointValue == target { return }
        if visitor.userData == nil { visitor.userData = NSMutableDictionary() }
        visitor.userData?["target"] = NSValue(point: target)

        visitor.removeAction(forKey: "walk")
        let points = waypoints(from: visitor.position, to: target, island: island, seatIndex: seatIndex)
        guard !points.isEmpty else { return }

        var actions: [SKAction] = []
        var from = visitor.position
        for pt in points {
            let distance = hypot(pt.x - from.x, pt.y - from.y)
            guard distance > 1 else { continue }
            actions.append(.move(to: pt, duration: max(0.05, TimeInterval(distance / walkSpeed))))
            from = pt
        }
        guard !actions.isEmpty else { return }
        visitor.run(.sequence(actions), withKey: "walk")
    }

    // MARK: - エントランスと入室演出

    /// 正面エントランスの扉の位置（奥壁の左上。中央の hub や吹き出しに被らない場所）
    private var doorPosition: CGPoint {
        CGPoint(x: 54, y: roomHeight - wallHeight)
    }

    /// 正面エントランスの扉ノード（両開きドア、上部に緑の誘導灯、手前にマット）
    private func entranceDoorNode() -> SKNode {
        let node = SKNode()
        node.name = "entranceDoor"

        // 玄関マット（床の上）
        let mat = SKShapeNode(rect: CGRect(x: -24, y: -10, width: 48, height: 12), cornerRadius: 2.0)
        mat.fillColor = DeskScene.doorMatColor
        mat.strokeColor = .secondaryLabelColor.withAlphaComponent(0.20)
        mat.lineWidth = 0.8
        mat.zPosition = -9980
        node.addChild(mat)

        // ドア枠（壁に埋め込まれた外枠）
        let frame = SKShapeNode(rect: CGRect(x: -21, y: 0, width: 42, height: wallHeight), cornerRadius: 1.5)
        frame.fillColor = DeskScene.doorFrameColor
        frame.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        frame.lineWidth = 1.0
        frame.zPosition = -9970
        node.addChild(frame)

        // 扉の奥（開いた時に見える廊下のあかり）
        let opening = SKShapeNode(rect: CGRect(x: -19, y: 0, width: 38, height: wallHeight - 8))
        opening.fillColor = DeskScene.doorOpeningColor
        opening.strokeColor = .clear
        opening.zPosition = -9965
        node.addChild(opening)

        // 左扉（開閉時に左端を軸にスケール変化）
        let leftLeafWrapper = SKNode()
        leftLeafWrapper.name = "leftLeaf"
        leftLeafWrapper.position = CGPoint(x: -19, y: 0)
        leftLeafWrapper.zPosition = -9950

        let leftLeaf = SKShapeNode(rect: CGRect(x: 0, y: 0, width: 18.5, height: wallHeight - 8), cornerRadius: 1)
        leftLeaf.fillColor = DeskScene.doorLeafColor
        leftLeaf.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        leftLeaf.lineWidth = 0.8
        leftLeafWrapper.addChild(leftLeaf)

        // 左ドアノブ（真鍮風の丸）
        let leftKnob = SKShapeNode(circleOfRadius: 1.1)
        leftKnob.fillColor = NSColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 0.9)
        leftKnob.strokeColor = .clear
        leftKnob.position = CGPoint(x: 15.5, y: (wallHeight - 8) / 2)
        leftLeafWrapper.addChild(leftKnob)
        node.addChild(leftLeafWrapper)

        // 右扉（開閉時に右端を軸にスケール変化）
        let rightLeafWrapper = SKNode()
        rightLeafWrapper.name = "rightLeaf"
        rightLeafWrapper.position = CGPoint(x: 19, y: 0)
        rightLeafWrapper.zPosition = -9950

        let rightLeaf = SKShapeNode(rect: CGRect(x: -18.5, y: 0, width: 18.5, height: wallHeight - 8), cornerRadius: 1)
        rightLeaf.fillColor = DeskScene.doorLeafColor
        rightLeaf.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        rightLeaf.lineWidth = 0.8
        rightLeafWrapper.addChild(rightLeaf)

        // 右ドアノブ
        let rightKnob = SKShapeNode(circleOfRadius: 1.1)
        rightKnob.fillColor = NSColor(red: 0.85, green: 0.75, blue: 0.35, alpha: 0.9)
        rightKnob.strokeColor = .clear
        rightKnob.position = CGPoint(x: -15.5, y: (wallHeight - 8) / 2)
        rightLeafWrapper.addChild(rightKnob)
        node.addChild(rightLeafWrapper)

        // 誘導灯（ドア上部のかもいに掲げる緑のランプ）
        let exitSign = SKShapeNode(rect: CGRect(x: -9, y: wallHeight - 7, width: 18, height: 5.5), cornerRadius: 1.2)
        exitSign.fillColor = NSColor(red: 0.15, green: 0.82, blue: 0.40, alpha: 0.92)
        exitSign.strokeColor = .white.withAlphaComponent(0.6)
        exitSign.lineWidth = 0.6
        exitSign.zPosition = -9940
        node.addChild(exitSign)

        return node
    }

    /// 正面エントランスの扉を開閉する
    private func animateDoor(open: Bool, duration: TimeInterval = 0.22) {
        guard let door = room.childNode(withName: "entranceDoor") else { return }
        let targetScale: CGFloat = open ? 0.12 : 1.0
        let leftAction = SKAction.scaleX(to: targetScale, duration: duration)
        let rightAction = SKAction.scaleX(to: targetScale, duration: duration)
        leftAction.timingMode = open ? .easeOut : .easeIn
        rightAction.timingMode = open ? .easeOut : .easeIn
        door.childNode(withName: "leftLeaf")?.run(leftAction, withKey: "doorSwing")
        door.childNode(withName: "rightLeaf")?.run(rightAction, withKey: "doorSwing")
    }

    /// 正面エントランス扉から指定の机の前までの歩行ルート
    private func arrivalWaypoints(to target: CGPoint, island: Int, seatIndex: Int) -> [CGPoint] {
        let topHallwayY = roomHeight - wallHeight - 16
        let doorFront = CGPoint(x: doorPosition.x, y: topHallwayY)
        let hub = hubPoint(island: island)
        let spread = columnPitch * CGFloat(seatColumns - 1)
        let col0X = hub.x - spread / 2
        let column = seatIndex % seatColumns

        let aisleX: CGFloat
        if seatColumns > 1 {
            let gapIndex = max(0, min(seatColumns - 2, column == 0 ? 0 : column - 1))
            let leftColX = col0X + columnPitch * CGFloat(gapIndex)
            let rightColX = leftColX + columnPitch
            aisleX = (leftColX + rightColX) / 2
        } else {
            // 机（幅184）の外側の南北主通路を通る（吹き出しは障害物ではないため余計な大回りはしない）
            aisleX = max(doorPosition.x + 30, min(col0X - (deskWidth / 2 + 14), target.x - 16))
        }

        var points: [CGPoint] = []

        // 1. 扉の正面（上部横通路）へ出る
        points.append(doorFront)

        // 2. 上部横通路を通って、机の左側の南北主通路 (aisleX) の入口へ進む
        if abs(doorFront.x - aisleX) >= 4 {
            points.append(CGPoint(x: aisleX, y: topHallwayY))
        }

        // 3. 南北主通路を自分の席の段まで進む
        if abs(topHallwayY - target.y) >= 4 {
            points.append(CGPoint(x: aisleX, y: target.y))
        }

        // 4. 自分の席（椅子の位置）に入る
        if abs(aisleX - target.x) >= 4 {
            points.append(target)
        }

        return points
    }

    /// 机の前や待機列から正面エントランス扉への歩行ルート
    private func departureWaypoints(from start: CGPoint, hubX: CGFloat, seatColumns: Int) -> [CGPoint] {
        let topHallwayY = roomHeight - wallHeight - 16
        let doorFront = CGPoint(x: doorPosition.x, y: topHallwayY)

        let col0X = hubX - columnPitch * CGFloat(seatColumns - 1) / 2
        // 机（幅184）の外側の南北主通路を通る。扉の手前へスムーズに誘導する
        let aisleX = max(doorPosition.x + 30, min(col0X - (deskWidth / 2 + 14), start.x - 16))

        var points: [CGPoint] = []

        // 1. 南北主通路（左側の通路）へ横移動
        if abs(start.x - aisleX) >= 4 {
            points.append(CGPoint(x: aisleX, y: start.y))
        }

        // 2. 南北主通路を北上して上部横通路へ
        if abs(start.y - topHallwayY) >= 4 {
            points.append(CGPoint(x: aisleX, y: topHallwayY))
        }

        // 3. 上部横通路を通って扉の正面へ進む
        if abs(aisleX - doorFront.x) >= 4 {
            points.append(doorFront)
        }

        return points
    }

    /// 終了した席やリポジトリの退室アニメーション。
    /// 席から立ち上がり、通路を通って正面エントランスの扉から退室する
    private func animateDepartures(seatIds: Set<String>, repoNames: Set<String>) {
        guard !seatIds.isEmpty || !repoNames.isEmpty else { return }

        let topHallwayY = roomHeight - wallHeight - 16
        let doorFront = CGPoint(x: doorPosition.x, y: topHallwayY)
        let doorSpawn = CGPoint(x: doorPosition.x, y: doorPosition.y + 6)

        var delay: TimeInterval = 0.0

        // リポジトリ全体の退室（hub担当者）
        for repo in repoNames {
            let nodeKey = "hub:\(repo)"
            guard let desk = room.childNode(withName: nodeKey) else { continue }
            let occupant = desk.childNode(withName: "occupant")
            guard occupant?.isHidden == false else { continue }

            let walker = person(tint: .labelColor)
            walker.setScale(1.2)
            walker.position = CGPoint(x: desk.position.x, y: desk.position.y + 30)
            walker.alpha = 0
            room.addChild(walker)
            departing[nodeKey] = walker

            let bobAction = SKAction.repeatForever(.sequence([
                .moveBy(x: 0, y: 1.2, duration: 0.12),
                .moveBy(x: 0, y: -1.2, duration: 0.12),
            ]))
            walker.run(bobAction, withKey: "bob")

            var actions: [SKAction] = []
            if delay > 0 {
                actions.append(.wait(forDuration: delay))
            }
            actions.append(.run { [weak desk, weak walker] in
                walker?.alpha = 1
                desk?.childNode(withName: "occupant")?.isHidden = true
                desk?.childNode(withName: "speechBubble")?.run(.fadeOut(withDuration: 0.2))
                desk?.run(.sequence([
                    .wait(forDuration: 0.4),
                    .fadeOut(withDuration: 0.6)
                ]))
            })

            let hubX = desk.position.x
            let waypoints = departureWaypoints(from: walker.position, hubX: hubX, seatColumns: seatColumns)
            var from = walker.position
            var requestedOpen = false
            for pt in waypoints {
                if !requestedOpen && hypot(pt.x - doorFront.x, pt.y - doorFront.y) < 4 {
                    requestedOpen = true
                    actions.append(.run { [weak self] in
                        self?.requestDoorOpen()
                    })
                }
                let dist = hypot(pt.x - from.x, pt.y - from.y)
                guard dist > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(dist / walkSpeed))))
                from = pt
            }

            if !requestedOpen {
                actions.append(.run { [weak self] in
                    self?.requestDoorOpen()
                })
            }

            actions.append(.group([
                .move(to: doorSpawn, duration: 0.35),
                .fadeOut(withDuration: 0.35)
            ]))
            actions.append(.run { [weak self, weak walker] in
                guard let self else { return }
                walker?.removeAction(forKey: "bob")
                walker?.removeFromParent()
                self.departing.removeValue(forKey: nodeKey)
                self.requestDoorClose()
                if self.departing.isEmpty {
                    if self.rebuildIfNeeded() {
                        if !self.pendingArrivalSeats.isEmpty || !self.pendingArrivalRepos.isEmpty {
                            self.animateArrivals(seatIds: self.pendingArrivalSeats, repoNames: self.pendingArrivalRepos)
                        }
                    } else {
                        self.refreshSeats()
                    }
                }
            })

            walker.run(.sequence(actions), withKey: "walk")
            delay += 0.25
        }

        // 各席の退室（作業担当エージェント）
        for seatId in seatIds {
            let nodeKey = seatId
            let desk = room.childNode(withName: "seat:\(seatId)")

            let walker: SKNode
            let wasSeated: Bool
            if let existing = visitors.removeValue(forKey: seatId) {
                walker = existing
                walker.userData?.removeObject(forKey: "target")
                walker.removeAction(forKey: "walk")
                wasSeated = false
            } else if let existing = returning.removeValue(forKey: seatId) {
                walker = existing
                walker.removeAction(forKey: "walk")
                wasSeated = false
            } else if let existing = arriving.removeValue(forKey: seatId) {
                walker = existing
                walker.removeAction(forKey: "walk")
                wasSeated = false
            } else if let desk = desk,
                      let occupant = desk.childNode(withName: "occupant"),
                      !occupant.isHidden {
                let newWalker = person(tint: .labelColor)
                newWalker.setScale(1.2)
                newWalker.position = CGPoint(x: desk.position.x, y: desk.position.y + 30)
                newWalker.alpha = 0
                room.addChild(newWalker)
                walker = newWalker
                wasSeated = true
            } else {
                continue
            }

            departing[nodeKey] = walker

            if walker.action(forKey: "bob") == nil {
                let bobAction = SKAction.repeatForever(.sequence([
                    .moveBy(x: 0, y: 1.2, duration: 0.12),
                    .moveBy(x: 0, y: -1.2, duration: 0.12),
                ]))
                walker.run(bobAction, withKey: "bob")
            }

            var actions: [SKAction] = []
            if delay > 0 {
                actions.append(.wait(forDuration: delay))
            }

            if wasSeated {
                actions.append(.run { [weak desk, weak walker] in
                    walker?.alpha = 1
                    desk?.childNode(withName: "occupant")?.isHidden = true
                    desk?.childNode(withName: "hand")?.isHidden = true
                    desk?.childNode(withName: "speechBubble")?.run(.fadeOut(withDuration: 0.2))
                    desk?.childNode(withName: "printedPaper")?.run(.fadeOut(withDuration: 0.2))
                    desk?.run(.sequence([
                        .wait(forDuration: 0.4),
                        .fadeOut(withDuration: 0.6)
                    ]))
                })
            } else {
                desk?.childNode(withName: "occupant")?.isHidden = true
                desk?.childNode(withName: "hand")?.isHidden = true
                desk?.childNode(withName: "speechBubble")?.run(.fadeOut(withDuration: 0.2))
                desk?.childNode(withName: "printedPaper")?.run(.fadeOut(withDuration: 0.2))
                desk?.run(.sequence([
                    .wait(forDuration: 0.4),
                    .fadeOut(withDuration: 0.6)
                ]))
            }

            let hubX = roomWidth / 2
            let waypoints = departureWaypoints(from: walker.position, hubX: hubX, seatColumns: seatColumns)
            var from = walker.position
            var requestedOpen = false
            for pt in waypoints {
                if !requestedOpen && hypot(pt.x - doorFront.x, pt.y - doorFront.y) < 4 {
                    requestedOpen = true
                    actions.append(.run { [weak self] in
                        self?.requestDoorOpen()
                    })
                }
                let dist = hypot(pt.x - from.x, pt.y - from.y)
                guard dist > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(dist / walkSpeed))))
                from = pt
            }

            if !requestedOpen {
                actions.append(.run { [weak self] in
                    self?.requestDoorOpen()
                })
            }

            actions.append(.group([
                .move(to: doorSpawn, duration: 0.35),
                .fadeOut(withDuration: 0.35)
            ]))
            actions.append(.run { [weak self, weak walker] in
                guard let self else { return }
                walker?.removeAction(forKey: "bob")
                walker?.removeFromParent()
                self.departing.removeValue(forKey: nodeKey)
                self.requestDoorClose()
                if self.departing.isEmpty {
                    if self.rebuildIfNeeded() {
                        if !self.pendingArrivalSeats.isEmpty || !self.pendingArrivalRepos.isEmpty {
                            self.animateArrivals(seatIds: self.pendingArrivalSeats, repoNames: self.pendingArrivalRepos)
                        }
                    } else {
                        self.refreshSeats()
                    }
                }
            })

            walker.run(.sequence(actions), withKey: "walk")
            delay += 0.25
        }
    }

    /// 新しく追加された席やリポジトリへの入室アニメーション。
    /// 正面エントランスから入ってきて、自分の席まで歩いて着席する
    private func animateArrivals(seatIds: Set<String>, repoNames: Set<String>) {
        guard !seatIds.isEmpty || !repoNames.isEmpty else { return }

        // 扉を開く
        requestDoorOpen()

        let topHallwayY = roomHeight - wallHeight - 16
        let doorSpawn = CGPoint(x: doorPosition.x, y: doorPosition.y + 6)
        let doorFront = CGPoint(x: doorPosition.x, y: topHallwayY)

        var delay: TimeInterval = 0.0

        // 新しいリポジトリの hub があれば、まず hub の担当者が入室
        for repo in repoNames {
            guard let islandIndex = islands.firstIndex(where: { $0.repo == repo }) else { continue }
            let hub = hubPoint(island: islandIndex)
            let hubChair = CGPoint(x: hub.x, y: hub.y + 30)

            let walker = person(tint: .labelColor)
            walker.setScale(1.2)
            walker.position = doorSpawn
            walker.alpha = 0
            room.addChild(walker)

            var actions: [SKAction] = []
            if delay > 0 {
                actions.append(.wait(forDuration: delay))
            }
            actions.append(.fadeIn(withDuration: 0.15))
            actions.append(.move(to: doorFront, duration: 0.25))

            // 扉から hub 机の椅子へのルート
            let aisleX = max(doorPosition.x + 30, hub.x - (hubDeskWidth / 2 + 14))
            let points = [
                doorFront,
                CGPoint(x: aisleX, y: topHallwayY),
                CGPoint(x: aisleX, y: hubChair.y),
                hubChair
            ]
            var from = doorFront
            for pt in points {
                let dist = hypot(pt.x - from.x, pt.y - from.y)
                guard dist > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(dist / walkSpeed))))
                from = pt
            }
            actions.append(.run { [weak self, weak walker] in
                walker?.removeAction(forKey: "bob")
                walker?.removeFromParent()
                self?.pendingArrivalRepos.remove(repo)
                if let desk = self?.room.childNode(withName: "hub:\(repo)"),
                   let occupant = desk.childNode(withName: "occupant") {
                    occupant.isHidden = false
                    occupant.setScale(1.2)
                    occupant.run(.sequence([
                        .scale(to: 1.38, duration: 0.12),
                        .scale(to: 1.2, duration: 0.12),
                    ]))
                }
            })

            let bobAction = SKAction.repeatForever(.sequence([
                .moveBy(x: 0, y: 1.2, duration: 0.12),
                .moveBy(x: 0, y: -1.2, duration: 0.12),
            ]))
            walker.run(bobAction, withKey: "bob")
            walker.run(.sequence(actions), withKey: "walk")

            delay += 0.35
        }

        // 各席の担当エージェントが入室
        for seatId in seatIds {
            guard let home = homeSpot(of: seatId) else {
                pendingArrivalSeats.remove(seatId)
                refreshSeatOccupant(id: seatId)
                continue
            }

            let walker = person(tint: .labelColor)
            walker.setScale(1.2)
            walker.position = doorSpawn
            walker.alpha = 0
            room.addChild(walker)
            arriving[seatId] = walker

            var actions: [SKAction] = []
            if delay > 0 {
                actions.append(.wait(forDuration: delay))
            }
            actions.append(.fadeIn(withDuration: 0.15))
            actions.append(.move(to: doorFront, duration: 0.25))

            let points = arrivalWaypoints(to: home.spot, island: home.island, seatIndex: home.seat)
            var from = doorFront
            for pt in points {
                let dist = hypot(pt.x - from.x, pt.y - from.y)
                guard dist > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(dist / walkSpeed))))
                from = pt
            }
            actions.append(.run { [weak self, weak walker] in
                walker?.removeAction(forKey: "bob")
                walker?.removeFromParent()
                self?.arriving.removeValue(forKey: seatId)
                self?.pendingArrivalSeats.remove(seatId)
                self?.refreshSeatOccupant(id: seatId)
                if let desk = self?.room.childNode(withName: "seat:\(seatId)"),
                   let occupant = desk.childNode(withName: "occupant") {
                    occupant.run(.sequence([
                        .scale(to: 1.38, duration: 0.12),
                        .scale(to: 1.2, duration: 0.12),
                    ]))
                }
            })

            let bobAction = SKAction.repeatForever(.sequence([
                .moveBy(x: 0, y: 1.2, duration: 0.12),
                .moveBy(x: 0, y: -1.2, duration: 0.12),
            ]))
            walker.run(bobAction, withKey: "bob")
            walker.run(.sequence(actions), withKey: "walk")

            delay += 0.35
        }

        // 全員が出たあとに扉を閉める
        run(.sequence([
            .wait(forDuration: delay + 0.35),
            .run { [weak self] in self?.requestDoorClose() }
        ]))
    }

    // MARK: - カメラ

    override func update(_ currentTime: TimeInterval) {
        // 手前のものほど後に描く。歩くたびに奥行きが変わるので毎フレーム引き直す
        for visitor in visitors.values { visitor.zPosition = -visitor.position.y }
        for visitor in returning.values { visitor.zPosition = -visitor.position.y }
        for arriver in arriving.values { arriver.zPosition = -arriver.position.y }
        for departer in departing.values { departer.zPosition = -departer.position.y }

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
        guard departing.isEmpty else { return }
        guard builtSkeleton == nil
                || columns != builtColumns
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
    /// **基本はカレントタブ（人間が作業している机）が最優先。**
    /// 画面外で要確認のエージェントがいても、カメラを強制的に奪わずに
    /// 画面縁の呼び出し吹き出しで知らせ、ユーザーがそれを押した時に切り替える。
    /// カレントタブが無い場合のみ、要確認の机にカメラを寄せる
    private func reconsiderFocus(at now: TimeInterval) {
        // 1. 人間がいま見ているタブがあれば、その机を最優先で映す
        if let current = firstCurrentSeat() {
            // もし人間がタブを明示的に切り替えたら、手動操作を即座に解除してその机へ寄せる
            if lastFollowedCurrentPoint != current.point {
                lastFollowedCurrentPoint = current.point
                isUserControlling = false
            }
            if !isUserControlling {
                if current.island != focusedIsland || focus != current.point {
                    focusedIsland = current.island
                    focus = current.point
                    switchedAt = now
                }
                return
            }
        }

        // 2. ユーザーが手動でパンやズームを操作している最中は、勝手にカメラを動かさない。
        // 最後の操作から 6 秒間何もなければ自動追従を再開する
        if isUserControlling {
            if now - lastUserControlTime >= 6.0 {
                isUserControlling = false
            } else {
                return
            }
        }

        // 3. カレントタブが無い場合のみ、要確認の机にカメラを寄せる
        if let calling = firstNeedingPerson() {
            focus = calling.point
            focusedIsland = calling.island
            switchedAt = now
            return
        }

        // 4. 新しく入室してきた人が歩いていれば、その人をカメラで追う
        if !arriving.isEmpty, let firstArriver = arriving.values.first {
            focus = firstArriver.position
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

    /// 人間がいま見ているタブに対応する机
    private func firstCurrentSeat() -> (island: Int, point: CGPoint)? {
        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.isCurrent {
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
        if abs(targetZoom - currentZoom) > 0.001 {
            let zoomRatio = 1 - pow(0.05, delta)
            currentZoom += (targetZoom - currentZoom) * zoomRatio
            eye.setScale(currentZoom)
        }
        let target = clampCamera(focus, zoom: currentZoom)
        // 1秒でおよそ 92% 詰める速さ。フレーム間隔に依らず同じ寄り方になる
        let ratio = 1 - pow(0.08, delta)
        eye.position = CGPoint(x: eye.position.x + (target.x - eye.position.x) * ratio,
                               y: eye.position.y + (target.y - eye.position.y) * ratio)
    }

    /// カメラが部屋の外を映さないように可動範囲を切る。
    /// ズーム率に応じた表示領域を計算し、部屋より広くなった軸は部屋の中央に置く
    private func clampCamera(_ point: CGPoint, zoom: CGFloat) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return point }
        let viewW = size.width * zoom
        let viewH = size.height * zoom
        func fit(_ value: CGFloat, room: CGFloat, view: CGFloat) -> CGFloat {
            guard room > view else { return room / 2 }
            return min(max(value, view / 2), room - view / 2)
        }
        return CGPoint(x: fit(point.x, room: roomWidth, view: viewW),
                       y: fit(point.y, room: roomHeight, view: viewH))
    }

    // MARK: - 画面外の要確認呼び出し吹き出し

    /// 画面外からの呼び出し吹き出しの外形パス。尾っぽが画面外（下または上）を指す
    private static func callingBubblePath(width: CGFloat, height: CGFloat, isDown: Bool) -> CGPath {
        let path = CGMutablePath()
        let hw = width / 2
        let r: CGFloat = 10
        let tailW: CGFloat = 9
        let tailH: CGFloat = 7

        if isDown {
            // 下端の中央に下向き（画面外）を指す三角の尾っぽ
            path.move(to: CGPoint(x: -hw + r, y: 0))
            path.addLine(to: CGPoint(x: -tailW, y: 0))
            path.addLine(to: CGPoint(x: 0, y: -tailH))
            path.addLine(to: CGPoint(x: tailW, y: 0))
            path.addLine(to: CGPoint(x: hw - r, y: 0))
            path.addArc(tangent1End: CGPoint(x: hw, y: 0), tangent2End: CGPoint(x: hw, y: r), radius: r)
            path.addLine(to: CGPoint(x: hw, y: height - r))
            path.addArc(tangent1End: CGPoint(x: hw, y: height), tangent2End: CGPoint(x: hw - r, y: height), radius: r)
            path.addLine(to: CGPoint(x: -hw + r, y: height))
            path.addArc(tangent1End: CGPoint(x: -hw, y: height), tangent2End: CGPoint(x: -hw, y: height - r), radius: r)
            path.addLine(to: CGPoint(x: -hw, y: r))
            path.addArc(tangent1End: CGPoint(x: -hw, y: 0), tangent2End: CGPoint(x: -hw + r, y: 0), radius: r)
            path.closeSubpath()
        } else {
            // 上端の中央に上向き（画面外）を指す三角の尾っぽ
            path.move(to: CGPoint(x: -hw + r, y: 0))
            path.addLine(to: CGPoint(x: hw - r, y: 0))
            path.addArc(tangent1End: CGPoint(x: hw, y: 0), tangent2End: CGPoint(x: hw, y: r), radius: r)
            path.addLine(to: CGPoint(x: hw, y: height - r))
            path.addArc(tangent1End: CGPoint(x: hw, y: height), tangent2End: CGPoint(x: hw - r, y: height), radius: r)
            path.addLine(to: CGPoint(x: tailW, y: height))
            path.addLine(to: CGPoint(x: 0, y: height + tailH))
            path.addLine(to: CGPoint(x: -tailW, y: height))
            path.addLine(to: CGPoint(x: -hw + r, y: height))
            path.addArc(tangent1End: CGPoint(x: -hw, y: height), tangent2End: CGPoint(x: -hw, y: height - r), radius: r)
            path.addLine(to: CGPoint(x: -hw, y: r))
            path.addArc(tangent1End: CGPoint(x: -hw, y: 0), tangent2End: CGPoint(x: -hw + r, y: 0), radius: r)
            path.closeSubpath()
        }
        return path
    }

    /// 画面外で要確認（助けを求めている）のエージェントがいることを知らせる呼び出し吹き出し。
    /// 画面の縁から吹き出しが出ているように見せ、クリックするとそのタブを開く
    private func callingBubbleNode(seat: DeskSeat, isDown: Bool, width: CGFloat) -> SKNode {
        let node = SKNode()
        node.name = "seat:\(seat.id)"

        let bubbleHeight: CGFloat = 34

        let path = DeskScene.callingBubblePath(width: width, height: bubbleHeight, isDown: isDown)
        let shape = SKShapeNode(path: path)
        shape.name = "seat:\(seat.id)"
        shape.fillColor = DeskScene.callingBubbleFillColor
        shape.strokeColor = DeskScene.callingBubbleStrokeColor
        shape.lineWidth = 1.4
        node.addChild(shape)

        // ふわふわと微かに脈動する演出で注意を引く
        shape.run(.repeatForever(.sequence([
            .scale(to: 1.025, duration: 0.6),
            .scale(to: 1.0, duration: 0.6),
        ])), withKey: "pulse")

        var leftX: CGFloat = -width / 2 + 14

        // 1. タブ番号バッジ (⌘1 など)
        if let tabNumber = seat.tabNumber {
            let badge = SKNode()
            badge.name = "seat:\(seat.id)"
            badge.position = CGPoint(x: leftX + 13, y: bubbleHeight / 2)

            let badgeBg = SKShapeNode(rect: CGRect(x: -13, y: -8, width: 26, height: 16), cornerRadius: 4.0)
            badgeBg.name = "seat:\(seat.id)"
            badgeBg.fillColor = DeskScene.callingBadgeBgColor
            badgeBg.strokeColor = DeskScene.callingBadgeStrokeColor
            badgeBg.lineWidth = 1.0
            badge.addChild(badgeBg)

            let badgeLabel = SKLabelNode(fontNamed: "SFMono-Bold")
            badgeLabel.name = "seat:\(seat.id)"
            badgeLabel.fontSize = 9.0
            badgeLabel.fontColor = DeskScene.callingBadgeTextColor
            badgeLabel.horizontalAlignmentMode = .center
            badgeLabel.verticalAlignmentMode = .center
            badgeLabel.text = "⌘\(tabNumber)"
            badge.addChild(badgeLabel)

            node.addChild(badge)
            leftX += 32
        }

        // 2. 手を振るアイコン
        let hand = DeskScene.handMark()
        hand.name = "seat:\(seat.id)"
        hand.setScale(0.85)
        hand.position = CGPoint(x: leftX + 10, y: bubbleHeight / 2 - 8)
        hand.run(.repeatForever(.sequence([
            .rotate(toAngle: 0.22, duration: 0.35),
            .rotate(toAngle: -0.15, duration: 0.35),
        ])), withKey: "wave")
        node.addChild(hand)
        leftX += 22

        // 3. タスク名ラベル
        let label = SKLabelNode(fontNamed: "SFMono-Bold")
        label.name = "seat:\(seat.id)"
        label.fontSize = 11.0
        label.fontColor = .labelColor
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: leftX, y: bubbleHeight / 2)
        let maxChars = seat.tabNumber != nil ? 18 : 22
        label.text = truncateScreenText(seat.name, limit: maxChars)
        node.addChild(label)

        // 4. 方向を示す矢印 (▼ または ▲)
        let arrow = SKLabelNode(fontNamed: "SFMono-Bold")
        arrow.name = "seat:\(seat.id)"
        arrow.fontSize = 10.0
        arrow.fontColor = DeskScene.callingBadgeStrokeColor
        arrow.horizontalAlignmentMode = .center
        arrow.verticalAlignmentMode = .center
        arrow.position = CGPoint(x: width / 2 - 14, y: bubbleHeight / 2)
        arrow.text = isDown ? "▼" : "▲"
        node.addChild(arrow)

        node.zPosition = 10000
        return node
    }

    private static let callingBubbleFillColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.22, green: 0.16, blue: 0.10, alpha: 0.98)
            : NSColor(red: 1.0, green: 0.96, blue: 0.90, alpha: 0.98)
    }

    private static let callingBubbleStrokeColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.98, green: 0.58, blue: 0.18, alpha: 0.95)
            : NSColor(red: 0.92, green: 0.46, blue: 0.08, alpha: 0.95)
    }

    private static let callingBadgeBgColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.20, blue: 0.08, alpha: 0.98)
            : NSColor(red: 0.98, green: 0.90, blue: 0.80, alpha: 0.98)
    }

    private static let callingBadgeStrokeColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.98, green: 0.60, blue: 0.15, alpha: 1.0)
            : NSColor(red: 0.90, green: 0.45, blue: 0.05, alpha: 1.0)
    }

    private static let callingBadgeTextColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
            : NSColor(red: 0.75, green: 0.32, blue: 0.02, alpha: 1.0)
    }

    /// 画面の外で手を挙げている机を、画面の縁の吹き出しで知らせる。
    ///
    /// カメラが現在タブを見ている間でも、画面外で助けを呼んでいる席があることが
    /// 吹き出しによって一目で分かり、クリックすればそのタブへ直接切り替えられる
    private func placeMarkers() {
        guard size.width >= 100 && size.height >= 80 else {
            if !activeMarkers.isEmpty {
                markers.removeAllChildren()
                activeMarkers.removeAll()
            }
            return
        }

        let halfW = size.width / 2
        let halfH = size.height / 2
        let sceneHalfW = halfW * currentZoom
        let sceneHalfH = halfH * currentZoom

        let viewportLeft = eye.position.x - sceneHalfW
        let viewportRight = eye.position.x + sceneHalfW
        let viewportBottom = eye.position.y - sceneHalfH
        let viewportTop = eye.position.y + sceneHalfH

        // 部屋の拡大縮小 (1.0 / currentZoom) に吹き出しの大きさも同期させる。
        // サイドバーの幅を突き抜けて左右が見切れるのを防ぐため、画面幅に応じた上限を設ける
        let baseBubbleWidth: CGFloat = 236
        let maxScale = max(0.45, (size.width - 24) / baseBubbleWidth)
        let bubbleScale = min(maxScale, max(0.42, 1.0 / currentZoom))
        let bubbleHeight: CGFloat = 34
        let tailH: CGFloat = 7
        let step: CGFloat = (bubbleHeight + 10) * bubbleScale

        // 画面外で要確認になっている机をリストアップ
        var offscreenCalling: [(seat: DeskSeat, isDown: Bool, distance: CGFloat)] = []
        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.needsPerson {
                let point = seatPoint(island: index, index: slot)
                // 机の頭上にある思考吹き出し（タブタイトルとバッジ）の領域。
                // 机の中心座標だけで判定すると、カメラを動かしたときに頭上のタブタイトルが
                // 先に画面外へ消えて見えなくなっているのに呼び出し吹き出しが出なくなってしまうため、
                // タブタイトルの外枠が見切れた時点で即座に画面外とみなす
                let bubbleLeft = point.x - 112
                let bubbleRight = point.x + 112
                let bubbleBottom = point.y + 68
                let bubbleTop = point.y + 104

                let isOffscreen = bubbleTop > viewportTop
                               || bubbleBottom < viewportBottom
                               || bubbleLeft < viewportLeft
                               || bubbleRight > viewportRight
                               || (point.y + 40) < viewportBottom
                               || (point.y - 40) > viewportTop
                guard isOffscreen else { continue }

                let isDown: Bool
                if bubbleBottom < viewportBottom || point.y < viewportBottom {
                    isDown = true
                } else if bubbleTop > viewportTop || point.y > viewportTop {
                    isDown = false
                } else {
                    isDown = point.y < eye.position.y
                }
                let distance = abs(point.y - eye.position.y)
                offscreenCalling.append((seat, isDown, distance))
            }
        }

        let downCalling = offscreenCalling.filter { $0.isDown }.sorted { $0.distance < $1.distance }.prefix(2)
        let upCalling = offscreenCalling.filter { !$0.isDown }.sorted { $0.distance < $1.distance }.prefix(2)

        var needed: [(key: String, seat: DeskSeat, isDown: Bool, baseY: CGFloat)] = []

        // 画面下端の吹き出し（下で呼んでいる人）：尾っぽの先端が画面下端に揃うよう配置
        for (idx, item) in downCalling.enumerated() {
            let key = "down:\(item.seat.id)"
            let baseY = -halfH + 6 + tailH * bubbleScale + CGFloat(idx) * step
            needed.append((key, item.seat, true, baseY))
        }

        // 画面上端の吹き出し（上で呼んでいる人）：尾っぽの先端が画面上端に揃うよう配置
        for (idx, item) in upCalling.enumerated() {
            let key = "up:\(item.seat.id)"
            let baseY = halfH - 6 - (bubbleHeight + tailH) * bubbleScale - CGFloat(idx) * step
            needed.append((key, item.seat, false, baseY))
        }

        // 毎フレームノードを作り直すと手の振りや脈動アニメーションが先頭に戻って
        // カクついてしまうため、差分がある時だけ生成・破棄し、通常は拡大率と座標のみ更新する
        let neededKeys = Set(needed.map(\.key))
        for (key, entry) in activeMarkers where !neededKeys.contains(key) {
            entry.node.removeFromParent()
            activeMarkers.removeValue(forKey: key)
        }

        for item in needed {
            let entry: MarkerEntry
            if let existing = activeMarkers[item.key],
               existing.name == item.seat.name,
               existing.tabNumber == item.seat.tabNumber {
                entry = existing
            } else {
                activeMarkers[item.key]?.node.removeFromParent()
                let bubble = callingBubbleNode(seat: item.seat, isDown: item.isDown, width: baseBubbleWidth)
                markers.addChild(bubble)
                let newEntry = MarkerEntry(node: bubble, name: item.seat.name, tabNumber: item.seat.tabNumber)
                activeMarkers[item.key] = newEntry
                entry = newEntry
            }

            entry.node.setScale(bubbleScale)
            entry.node.position = CGPoint(x: 0, y: item.baseY)
        }
    }

    // MARK: - 操作とイベント (パン・ズーム・クリック)

    /// 指定した座標にある机の席 ID を探す
    private func seatId(at point: CGPoint) -> String? {
        for node in nodes(at: point) {
            var current: SKNode? = node
            while let candidate = current {
                if let name = candidate.name, name.hasPrefix("seat:") {
                    return String(name.dropFirst("seat:".count))
                }
                current = candidate.parent
            }
        }
        return nil
    }

    /// ユーザーによる手動操作があったことを記録し、自動追従を一時停止する
    private func userInteracted() {
        isUserControlling = true
        lastUserControlTime = lastUpdate > 0 ? lastUpdate : CACurrentMediaTime()
    }

    /// 指定したシーン座標（カーソル位置など）を中心にカメラを拡大・縮小する
    private func applyZoom(factor: CGFloat, anchorInScene: CGPoint) {
        userInteracted()
        let newZoom = min(max(currentZoom * factor, minZoom), maxZoom)
        guard abs(newZoom - currentZoom) > 0.0001 else { return }

        // カーソルが指しているシーンの点をズーム後も同じ画面位置に留めるため、
        // ズーム比率 (newZoom / currentZoom) を掛けてカメラ位置を補正する
        let zoomRatio = newZoom / currentZoom
        let newFocus = CGPoint(
            x: anchorInScene.x - (anchorInScene.x - focus.x) * zoomRatio,
            y: anchorInScene.y - (anchorInScene.y - focus.y) * zoomRatio
        )
        currentZoom = newZoom
        targetZoom = newZoom
        eye.setScale(currentZoom)
        focus = clampCamera(newFocus, zoom: currentZoom)
        eye.position = focus
    }

    /// クリック開始。ダブルクリックならズームリセット、単一クリックならドラッグ開始または机の選択準備
    override func mouseDown(with event: NSEvent) {
        let point = event.location(in: self)
        let clickedSeat = seatId(at: point)

        if event.clickCount == 2 {
            if let clickedSeat {
                onOpen?(clickedSeat)
            } else {
                // 背景をダブルクリックした場合は等倍 (1.0) に戻し、自動追従を即座に再開する
                targetZoom = 1.0
                isUserControlling = false
                lastFollowedCurrentPoint = nil
            }
            return
        }

        dragStartInWindow = event.locationInWindow
        dragStartFocus = focus
        isDragging = false
        clickedSeatId = clickedSeat
    }

    /// マウスドラッグでカメラを直接パン移動する
    override func mouseDragged(with event: NSEvent) {
        guard let startInWindow = dragStartInWindow,
              let startFocus = dragStartFocus else { return }
        let currentInWindow = event.locationInWindow
        let dx = currentInWindow.x - startInWindow.x
        let dy = currentInWindow.y - startInWindow.y
        let distance = hypot(dx, dy)

        // わずかな手ブレでクリックをドラッグと誤認しないよう、4pt 以上動いてからドラッグとみなす
        if !isDragging && distance > 4 {
            isDragging = true
            NSCursor.closedHand.push()
        }

        guard isDragging else { return }
        userInteracted()

        // 掴んだ床がそのままマウスカーソルに追従するよう、画面の移動量にズーム率を掛けてカメラを逆方向に送る
        let newFocus = CGPoint(
            x: startFocus.x - dx * currentZoom,
            y: startFocus.y - dy * currentZoom
        )
        focus = clampCamera(newFocus, zoom: currentZoom)
        eye.position = focus
    }

    /// 指定した席 ID の島番号と机座標を探す
    private func findSeatPoint(id: String) -> (island: Int, point: CGPoint)? {
        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.id == id {
                return (index, seatPoint(island: index, index: slot))
            }
        }
        return nil
    }

    /// マウス離脱。ドラッグ中ならカーソルを戻し、机や呼び出し吹き出しのクリックだった場合はそのタスクを開く
    override func mouseUp(with event: NSEvent) {
        if isDragging {
            NSCursor.pop()
            isDragging = false
        } else if let seatId = clickedSeatId {
            onOpen?(seatId)
            // クリックした席の座標が分かれば、台帳の更新を待たずに即座にカメラを向ける
            if let spot = findSeatPoint(id: seatId) {
                focus = spot.point
                focusedIsland = spot.island
                switchedAt = lastUpdate
                isUserControlling = false
                lastFollowedCurrentPoint = spot.point
            }
        }
        dragStartInWindow = nil
        dragStartFocus = nil
        clickedSeatId = nil
    }

    /// スクロールホイールおよびトラックパッドの2本指スワイプによるパン・ズーム操作
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            // ⌘ + スクロール: マウスカーソル位置を中心に拡大縮小する
            let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
            guard abs(deltaY) > 0.01 else { return }
            let factor = pow(1.003, -deltaY)
            let anchor = event.location(in: self)
            applyZoom(factor: factor, anchorInScene: anchor)
        } else {
            // 通常のスクロール: トラックパッドの2本指スワイプやマウスホイールで部屋をパン移動する
            let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 20
            let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 20
            guard abs(deltaX) > 0.1 || abs(deltaY) > 0.1 else { return }
            userInteracted()
            let newFocus = CGPoint(
                x: focus.x - deltaX * currentZoom,
                y: focus.y - deltaY * currentZoom
            )
            focus = clampCamera(newFocus, zoom: currentZoom)
            eye.position = focus
        }
    }

    /// トラックパッドのピンチジェスチャによる拡大縮小
    override func magnify(with event: NSEvent) {
        // magnification は前フレームからの増分。正（広げる）ならズームイン（zoom縮小）、負ならズームアウト
        let factor = 1.0 / (1.0 + event.magnification)
        let anchor = event.location(in: self)
        applyZoom(factor: factor, anchorInScene: anchor)
    }
}
