import AppKit
import Foundation
import Model
import Resources
import SpriteKit

/// 斜め上から見た事務所の SpriteKit シーン。
///
/// 机の配置・床の描画・入退室アニメーション・カメラ追従などの全体の振る舞いを統括するオーケストレーター。
final class DeskScene: SKScene {
    // MARK: - 公開インターフェース

    /// 机をクリックした時に開くハンドラ（セッションIDが渡る）
    var onOpen: ((String) -> Void)?

    // MARK: - サブコンポーネント

    let cameraManager = DeskCameraManager()

    // MARK: - 寸法とレイアウト

    /// 人が床を歩く速さ (pt/秒)
    private let walkSpeed: CGFloat = 120
    /// エージェントが飛ぶ速さ (pt/秒)。
    ///
    /// 机や壁を避けて通路を辿らせると、リポジトリが増えて床が広がるほど移動が長くなる。
    /// エージェントは飛べることにして、間取りに関係なく直線で結ぶ。
    /// 人（リポジトリの担当者）は床を歩いたままにして、両者の違いを動きでも出す
    private let flySpeed: CGFloat = 320

    /// 間取りをどこまで出すか。サイドバーは `.compact`、オフィス窓は `.suites`
    var layoutStyle: OfficeLayoutStyle = .compact {
        didSet {
            guard layoutStyle != oldValue else { return }
            rebuildIfNeeded()
        }
    }

    /// 北壁に並ぶレート上限ボードが見切れないために要る部屋の最小幅
    private var minContentWidth: CGFloat {
        let boardCount = max(2, rateLimits.count)
        return boardCount >= 3 ? CGFloat(boardCount - 1) * 155 + 460 : 580
    }

    /// 間取りの計算結果。台帳・表示領域・見せ方が変わらない限り使い回す。
    /// `layout` は1フレームに何度も引かれるので、その都度組み直すと無駄が大きい
    private var cachedPlan: OfficeFloorPlan?
    private var cachedPlanKey: String?

    private var planKey: String {
        "\(skeleton(of: islands))|\(Int(size.width))x\(Int(size.height))|\(layoutStyle)|\(Int(minContentWidth))"
    }

    private var plan: OfficeFloorPlan {
        let key = planKey
        if let cachedPlan, cachedPlanKey == key { return cachedPlan }
        let built = OfficeFloorPlan.build(
            islands: islands,
            viewport: size,
            style: layoutStyle,
            minContentWidth: minContentWidth,
            noOrganizationName: Localized.text("app.group.no_organization"))
        cachedPlan = built
        cachedPlanKey = key
        return built
    }

    private var roomWidth: CGFloat { plan.size.width }
    private var roomHeight: CGFloat { plan.size.height }

    var layout: DeskLayout { DeskLayout(plan: plan) }

    // MARK: - シーンノードと状態

    private var room = SKNode()
    private let eye = SKCameraNode()
    private let markers = SKNode()

    private var builtPlanKey: String?
    private var builtWhiteboardKeys: [String] = []

    private var islands: [DeskIsland] = []
    private var rateLimits: [AgentQuotaSummary] = []
    private var whiteboardNodes: [WhiteboardNode] = []
    private weak var loungeNode: OfficeLoungeNode?
    private var activity: [Double] = []
    private var lastUpdate: TimeInterval = 0

    // 移動中のエージェント
    private var visitors: [String: PersonNode] = [:]
    private var returning: [String: PersonNode] = [:]
    private var arriving: [String: PersonNode] = [:]
    private var departing: [String: PersonNode] = [:]
    // 共用ラウンジで休憩中（または向かっている最中）のエージェント
    private var resting: [String: PersonNode] = [:]
    // ラウンジから自席へ戻っている最中のエージェント
    private var leavingLounge: [String: PersonNode] = [:]
    // 休憩中の人が座っているラウンジの席番号。組み直しをまたいでも変えない
    private var restSeats: [String: Int] = [:]

    // 扉の開閉要求カウンタ
    private var openDoorCount: Int = 0

    // 増分検出用
    private var pendingArrivalSeats: Set<String> = []
    private var pendingArrivalRepos: Set<String> = []
    private var knownSeatIds: Set<String> = []
    private var knownRepos: Set<String> = []
    private var hasInitializedArrivals = false
    /// 部屋を組み直した直後の反映かどうか。歩かせずに目的地へ置き直す
    private var isRestoringPlacement = false
    private let createdAt = Date()

    // MARK: - ライフサイクル

    /// ズーム倍率等の状態永続化キー（オフィスウィンドウで使用）
    var persistenceKey: String? {
        didSet {
            loadSavedZoom()
        }
    }

    override func didMove(to view: SKView) {
        if eye.parent == nil {
            addChild(eye)
            camera = eye
            eye.addChild(markers)
        }
        loadSavedZoom()
        rebuildIfNeeded()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        rebuildIfNeeded()
    }

    // MARK: - 台帳データの受け取り

    func apply(islands: [DeskIsland], rateLimits: [AgentQuotaSummary] = []) {
        self.islands = islands
        self.rateLimits = rateLimits

        let currentSeats = Set(islands.flatMap { $0.seats.map(\.id) })
        let currentRepos = Set(islands.map(\.repo))

        if !hasInitializedArrivals {
            knownSeatIds = currentSeats
            knownRepos = currentRepos
            // 起動直後、台帳の読み込みが非同期で完了する前に空の配列が渡ってくることがある。
            // 席またはリポジトリが存在する最初のデータを受け取った時点、
            // または起動から一定時間（1.5秒）経過した時点で初期化完了とし、
            // その時点のセッションは「最初から着席している既存セッション」として扱う
            if !currentSeats.isEmpty || !currentRepos.isEmpty || Date().timeIntervalSince(createdAt) > 1.5 {
                hasInitializedArrivals = true
            }
            if !rebuildIfNeeded() {
                refreshSeats()
                refreshWhiteboards()
            }
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
            pendingArrivalSeats.subtract(departedSeats)
            pendingArrivalRepos.subtract(departedRepos)
            animateDepartures(seatIds: departedSeats, repoNames: departedRepos)
        }

        let rebuilt = rebuildIfNeeded()
        if !rebuilt {
            refreshSeats()
            refreshWhiteboards()
        }

        if !newSeats.isEmpty || !newRepos.isEmpty {
            animateArrivals(seatIds: newSeats, repoNames: newRepos)
        }
    }

    private func skeleton(of islands: [DeskIsland]) -> String {
        islands.map { "\($0.repo)/\($0.organizationKey)/\($0.seats.map(\.id).joined(separator: ","))" }
            .joined(separator: "|")
    }

    // MARK: - 部屋の構築と再構築

    @discardableResult
    private func rebuildIfNeeded() -> Bool {
        guard size.height > 80 else { return false }
        // 退室中・入室中のエージェントがいる間は部屋の組み直しを保留し、歩き終わるまで待つ
        guard departing.isEmpty && arriving.isEmpty else { return false }
        let wantedKeys = Self.effectiveSummaries(from: rateLimits).map(\.key)
        guard planKey != builtPlanKey || wantedKeys != builtWhiteboardKeys else { return false }
        rebuild()
        return true
    }

    private func rebuild() {
        guard size.height > 80 else { return }

        room.removeFromParent()
        room = SKNode()
        addChild(room)

        markers.removeAllChildren()
        cameraManager.activeMarkers.removeAll()
        visitors.removeAll()
        returning.removeAll()
        arriving.removeAll()
        departing.removeAll()
        resting.removeAll()
        leavingLounge.removeAll()
        openDoorCount = 0
        activity = Array(repeating: 0, count: islands.count)
        builtPlanKey = planKey
        builtWhiteboardKeys = Self.effectiveSummaries(from: rateLimits).map(\.key)

        buildFloor()
        buildSuites()

        let layout = self.layout
        for (index, island) in islands.enumerated() {
            let orgName = island.organizationName ?? Localized.text("app.group.no_organization")
            let hubNode = DeskFurnitureNode(at: layout.hubPoint(island: index),
                                            label: island.repo, isHub: true, seat: nil,
                                            orgName: orgName)
            if pendingArrivalRepos.contains(island.repo) {
                hubNode.occupant.isHidden = true
            }
            room.addChild(hubNode)

            for (slot, seat) in island.seats.enumerated() {
                let seatNode = DeskFurnitureNode(at: layout.seatPoint(island: index, index: slot),
                                                 label: seat.name, isHub: false, seat: seat)
                if pendingArrivalSeats.contains(seat.id) {
                    seatNode.occupant.isHidden = true
                }
                room.addChild(seatNode)
            }
        }

        // 組み直しで人のノードは作り直しになる。そのまま普段の反映を通すと、
        // すでに待機列やソファに着いていた人まで自席から歩き直すことになるので、
        // この1回だけは目的地に置き直すだけにする
        isRestoringPlacement = true
        refreshSeats()
        isRestoringPlacement = false

        if cameraManager.isDragging {
            NSCursor.pop()
            cameraManager.isDragging = false
        }
        cameraManager.dragStartInWindow = nil
        cameraManager.dragStartFocus = nil
        cameraManager.clickedSeatId = nil

        cameraManager.focusedIsland = min(cameraManager.focusedIsland, max(0, islands.count - 1))
        cameraManager.focus = layout.hubPoint(island: cameraManager.focusedIsland)
        eye.setScale(cameraManager.currentZoom)
        eye.position = cameraManager.clampCamera(cameraManager.focus, zoom: cameraManager.currentZoom, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: size)
    }

    private func buildFloor() {
        let floor = SKShapeNode(rect: CGRect(x: 0, y: 0, width: roomWidth, height: roomHeight))
        floor.fillColor = .secondaryLabelColor.withAlphaComponent(0.06)
        floor.strokeColor = .clear
        floor.zPosition = -10000
        room.addChild(floor)

        let tile: CGFloat = 44
        for x in stride(from: 0, through: roomWidth, by: tile) {
            room.addChild(hairline(from: CGPoint(x: x, y: 0), to: CGPoint(x: x, y: roomHeight)))
        }
        for y in stride(from: 0, through: roomHeight, by: tile) {
            room.addChild(hairline(from: CGPoint(x: 0, y: y), to: CGPoint(x: roomWidth, y: y)))
        }

        let wall = SKShapeNode(rect: CGRect(x: 0, y: roomHeight - layout.wallHeight,
                                            width: roomWidth, height: layout.wallHeight))
        wall.fillColor = .secondaryLabelColor.withAlphaComponent(0.12)
        wall.strokeColor = .clear
        wall.zPosition = -9990
        room.addChild(wall)

        let baseboard = SKShapeNode(rect: CGRect(x: 0, y: roomHeight - layout.wallHeight - 1.5,
                                                 width: roomWidth, height: 1.5))
        baseboard.fillColor = .secondaryLabelColor.withAlphaComponent(0.25)
        baseboard.strokeColor = .clear
        baseboard.zPosition = -9985
        room.addChild(baseboard)

        let door = EntranceDoorNode(wallHeight: layout.wallHeight)
        door.position = layout.doorPosition
        room.addChild(door)

        whiteboardNodes.removeAll()
        let effective = Self.effectiveSummaries(from: rateLimits)
        let positions = layout.whiteboardPositions(count: effective.count)
        for (i, summary) in effective.enumerated() {
            let whiteboard = WhiteboardNode(summary: summary)
            whiteboard.position = positions[i]
            room.addChild(whiteboard)
            whiteboardNodes.append(whiteboard)
        }
    }

    /// 組織ごとのスイート（壁・扉・組織銘板）と、その中のリポジトリ区画の仕切りを敷く
    private func buildSuites() {
        let plan = self.plan
        for suite in plan.suites {
            let node = OfficeSuiteNode(suite: suite,
                                       showsWalls: plan.style.showsWalls,
                                       showsSideDoors: plan.style.showsLounge)
            room.addChild(node)

            for planter in suite.planters {
                room.addChild(OfficePlanterNode(planter: planter))
            }
        }

        if let lounge = plan.lounge {
            let node = OfficeLoungeNode(lounge: lounge)
            room.addChild(node)
            loungeNode = node
        } else {
            loungeNode = nil
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

    private func validateLayout() {
        guard size.height > 80 else { return }
        guard departing.isEmpty && arriving.isEmpty else { return }
        guard builtPlanKey == nil || builtPlanKey != planKey else { return }
        rebuild()
    }

    // MARK: - 机の見た目更新

    private func refreshSeats() {
        // 休憩の出入りを先に決める。あとで机を着替えさせるときに
        // 「席を外している」判定へ反映する必要があるため
        updateLounge()

        var queued: Set<String> = []
        for (index, island) in islands.enumerated() {
            for seat in island.seats {
                guard let desk = room.childNode(withName: "seat:\(seat.id)") as? DeskFurnitureNode else { continue }
                desk.dress(as: seat, isAway: isAway(seat.id))
            }
            queued.formUnion(updateQueue(island: index))
        }
        dismissVisitors(keeping: queued)
    }

    /// その席の作業者がいま机を離れているか
    private func isAway(_ id: String) -> Bool {
        visitors[id] != nil
            || returning[id] != nil
            || arriving[id] != nil
            || departing[id] != nil
            || resting[id] != nil
            || leavingLounge[id] != nil
            || pendingArrivalSeats.contains(id)
    }

    private func homeSpot(of id: String) -> (island: Int, seat: Int, spot: CGPoint)? {
        for (index, island) in islands.enumerated() {
            if let seat = island.seats.firstIndex(where: { $0.id == id }) {
                return (index, seat, layout.chairSpot(island: index, seat: seat))
            }
        }
        return nil
    }

    // MARK: - 待機列と移動

    private func updateQueue(island index: Int) -> Set<String> {
        let island = islands[index]
        var slot = 0
        var standing = Set<String>()

        for (seatIndex, seat) in island.seats.enumerated()
        where seat.status == TaskStatus.waiting
            // まだ入口から歩いてきている最中の人は席にも着いていない。
            // ここで待機列にも立たせると、同じ人が2人に見える
            && !pendingArrivalSeats.contains(seat.id) {
            standing.insert(seat.id)
            let target = layout.queuePoint(island: index, slot: slot)
            slot += 1

            let visitor: PersonNode
            if let existing = visitors[seat.id] {
                visitor = existing
            } else if let returningVisitor = returning.removeValue(forKey: seat.id) {
                visitor = returningVisitor
                visitors[seat.id] = visitor
            } else {
                visitor = PersonNode(kind: .agent)
                visitor.setScale(1.2)
                // 組み直しの置き直しなら、もう並んでいた場所からやり直す。
                // 自席から出発させると、部屋が組み変わるたびに全員が席を立つ
                visitor.position = isRestoringPlacement
                    ? target
                    : layout.chairSpot(island: index, seat: seatIndex)
                room.addChild(visitor)
                visitors[seat.id] = visitor
            }
            send(visitor, to: target, island: index, seatIndex: seatIndex)
        }
        return standing
    }

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

            fly(visitor, to: home.spot) { [weak self, weak visitor] in
                visitor?.stopBobbing()
                visitor?.removeFromParent()
                self?.returning.removeValue(forKey: id)
                self?.refreshSeatOccupant(id: id)
            }
        }
    }

    private func send(_ visitor: PersonNode, to target: CGPoint, island: Int, seatIndex: Int) {
        if let current = visitor.userData?["target"] as? NSValue,
           current.pointValue == target { return }
        if visitor.userData == nil { visitor.userData = NSMutableDictionary() }
        visitor.userData?["target"] = NSValue(point: target)
        visitor.removeAction(forKey: "walk")

        fly(visitor, to: target) { [weak visitor] in
            visitor?.stopBobbing()
        }
    }

    private func refreshSeatOccupant(id: String) {
        guard let desk = room.childNode(withName: "seat:\(id)") as? DeskFurnitureNode else { return }
        for island in islands {
            if let seat = island.seats.first(where: { $0.id == id }) {
                desk.dress(as: seat, isAway: isAway(id))
                return
            }
        }
    }

    // MARK: - 共用ラウンジでの休憩

    /// タスクを終えて確認も済んだエージェントをラウンジへ送り、
    /// また動き出したエージェントを自席へ戻す。
    ///
    /// 送る相手を `seen`（完了かつ確認済み）に限るのは、`done` のあいだは
    /// まだ手を挙げて人を待っているため。席を立つのは呼びかけが済んでから
    private func updateLounge() {
        guard layout.plan.lounge != nil else { return }

        var counts: [OfficeLoungeNode.Board: Int] = [:]
        var attention: [OfficeLoungeNode.Attention] = []
        var onBreak: [(id: String, island: Int, slot: Int)] = []

        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() {
                let board = OfficeLoungeNode.board(for: seat)
                counts[board, default: 0] += 1
                if board == .needsPerson {
                    attention.append(OfficeLoungeNode.Attention(name: seat.name,
                                                                repo: island.repo,
                                                                request: seat.request))
                }

                // ラウンジへ送るのは `seen` だけ。ディスプレイの「休憩中」は
                // サイドバーの完了の箱と同じ範囲なので、こちらより広い。
                // 入口から歩いてきている最中の人は、着席してから改めて送る
                guard seat.status == TaskStatus.seen,
                      !pendingArrivalSeats.contains(seat.id) else { continue }
                onBreak.append((seat.id, index, slot))
            }
        }

        assignRestSeats(to: onBreak.map(\.id))
        for entry in onBreak {
            sendToLounge(id: entry.id, island: entry.island, slot: entry.slot,
                         seatIndex: restSeats[entry.id] ?? 0)
        }

        let stillResting = Set(onBreak.map(\.id))
        for (id, walker) in resting where !stillResting.contains(id) {
            returnFromLounge(id: id, walker: walker)
        }

        loungeNode?.setCounts(counts, attention: attention)
    }

    /// 休憩に入った人へラウンジの席を割り当てる。
    ///
    /// 並び順で毎回振り直すと、誰かが新しく休憩に入っただけで先にいた人の席がずれる。
    /// 席がずれた人は座り直しに立ち上がるので、ラウンジ全体がその都度シャッフルされてしまう。
    /// いったん座った席はその人が休憩を終えるまで手を付けず、空いた席だけを新しい人へ回す
    private func assignRestSeats(to ids: [String]) {
        restSeats = restSeats.filter { ids.contains($0.key) }

        let capacity = layout.restSpotCount
        guard capacity > 0 else { return }

        var taken = Set(restSeats.values)
        for id in ids where restSeats[id] == nil {
            // 席が足りなければ番号を折り返す。`restSpot` 側で剰余を取るので相席になる
            let free = (0..<capacity).first { !taken.contains($0) } ?? taken.count
            restSeats[id] = free
            taken.insert(free)
        }
    }

    private func sendToLounge(id: String, island: Int, slot: Int, seatIndex: Int) {
        guard let spot = layout.restSpot(index: seatIndex) else { return }

        let walker: PersonNode
        if let existing = resting[id] {
            walker = existing
            // すでに同じ席へ向かっているなら歩き直させない
            if let current = walker.userData?["seat"] as? NSValue, current.pointValue == spot { return }
        } else if let coming = leavingLounge.removeValue(forKey: id) {
            // 戻る途中でまた休憩に入った。その場から向き直る
            walker = coming
            resting[id] = walker
        } else {
            walker = PersonNode(kind: .agent)
            walker.setScale(1.2)
            // 組み直しの置き直しなら、もう座っていた席へ直接戻す。
            // 自席から歩かせると、部屋が組み変わるたびに休憩中の全員が往復する
            walker.position = isRestoringPlacement
                ? spot
                : layout.chairSpot(island: island, seat: slot)
            room.addChild(walker)
            resting[id] = walker
        }

        if walker.userData == nil { walker.userData = NSMutableDictionary() }
        walker.userData?["seat"] = NSValue(point: spot)

        // すでに座面にいるなら歩くルートを組まない。
        // ルートは区画から扉を回って戻ってくる形なので、距離が 0 でも一周してしまう
        guard hypot(walker.position.x - spot.x, walker.position.y - spot.y) >= 2 else {
            walker.stopBobbing()
            return
        }

        fly(walker, to: spot) { [weak walker] in
            walker?.stopBobbing()
        }
    }

    private func returnFromLounge(id: String, walker: PersonNode) {
        resting.removeValue(forKey: id)
        walker.userData?.removeObject(forKey: "seat")

        guard let home = homeSpot(of: id) else {
            walker.removeFromParent()
            return
        }
        leavingLounge[id] = walker

        fly(walker, to: home.spot) { [weak self, weak walker] in
            walker?.stopBobbing()
            walker?.removeFromParent()
            self?.leavingLounge.removeValue(forKey: id)
            self?.refreshSeatOccupant(id: id)
        }
    }

    /// エージェントを目的地までまっすぐ飛ばす。
    ///
    /// 通路を辿らないので、机やプランターや壁の位置に関係なく最短で着く
    private func fly(_ walker: PersonNode, to target: CGPoint, completion: @escaping () -> Void) {
        walker.removeAction(forKey: "walk")

        let distance = hypot(target.x - walker.position.x, target.y - walker.position.y)
        guard distance > 1 else {
            completion()
            return
        }

        walker.startHovering()
        walker.run(.sequence([Self.flight(to: target, distance: distance, speed: flySpeed),
                              .run(completion)]),
                   withKey: "walk")
    }

    /// 飛行の移動アクション。飛び立ちと着地をなめらかにする
    private static func flight(to target: CGPoint, distance: CGFloat, speed: CGFloat) -> SKAction {
        let move = SKAction.move(to: target, duration: max(0.12, TimeInterval(distance / speed)))
        move.timingMode = .easeInEaseOut
        return move
    }

    // MARK: - 扉の開閉連動

    private func requestDoorOpen() {
        openDoorCount += 1
        (room.childNode(withName: "entranceDoor") as? EntranceDoorNode)?.animate(open: true)
    }

    private func requestDoorClose() {
        openDoorCount = max(0, openDoorCount - 1)
        if openDoorCount == 0 {
            (room.childNode(withName: "entranceDoor") as? EntranceDoorNode)?.animate(open: false)
        }
    }

    // MARK: - 入室アニメーション

    private func animateArrivals(seatIds: Set<String>, repoNames: Set<String>) {
        guard !seatIds.isEmpty || !repoNames.isEmpty else { return }

        requestDoorOpen()

        let doorSpawn = layout.doorSpawn
        let doorFront = layout.doorFront

        var delay: TimeInterval = 0.0

        for repo in repoNames {
            guard let islandIndex = islands.firstIndex(where: { $0.repo == repo }) else { continue }

            let walker = PersonNode(kind: .human)
            walker.setScale(1.2)
            walker.position = doorSpawn
            walker.alpha = 0
            room.addChild(walker)

            var actions: [SKAction] = []
            if delay > 0 { actions.append(.wait(forDuration: delay)) }
            actions.append(.fadeIn(withDuration: 0.15))
            actions.append(.move(to: doorFront, duration: 0.25))

            let points = layout.hubArrivalWaypoints(island: islandIndex)
            var from = doorFront
            for pt in points {
                let dist = hypot(pt.x - from.x, pt.y - from.y)
                guard dist > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(dist / walkSpeed))))
                from = pt
            }
            actions.append(.run { [weak self, weak walker] in
                guard let self else { return }
                walker?.stopBobbing()
                walker?.removeFromParent()
                self.pendingArrivalRepos.remove(repo)
                if let desk = self.room.childNode(withName: "hub:\(repo)") as? DeskFurnitureNode {
                    desk.occupant.isHidden = false
                    desk.occupant.setScale(1.2)
                    desk.occupant.cheer()
                }
                if self.arriving.isEmpty {
                    _ = self.rebuildIfNeeded()
                }
            })

            walker.startBobbing()
            walker.run(.sequence(actions), withKey: "walk")
            delay += 0.35
        }

        for seatId in seatIds {
            guard let home = homeSpot(of: seatId) else {
                pendingArrivalSeats.remove(seatId)
                refreshSeatOccupant(id: seatId)
                continue
            }

            let walker = PersonNode(kind: .agent)
            walker.setScale(1.2)
            walker.position = doorSpawn
            walker.alpha = 0
            room.addChild(walker)
            arriving[seatId] = walker

            var actions: [SKAction] = []
            if delay > 0 { actions.append(.wait(forDuration: delay)) }
            actions.append(.fadeIn(withDuration: 0.15))
            actions.append(.move(to: doorFront, duration: 0.25))

            // 扉をくぐったら、あとは自席までまっすぐ飛ぶ
            actions.append(.run { [weak walker] in walker?.startHovering() })
            actions.append(Self.flight(to: home.spot,
                                       distance: hypot(home.spot.x - doorFront.x,
                                                       home.spot.y - doorFront.y),
                                       speed: flySpeed))
            actions.append(.run { [weak self, weak walker] in
                guard let self else { return }
                walker?.stopBobbing()
                walker?.removeFromParent()
                self.arriving.removeValue(forKey: seatId)
                self.pendingArrivalSeats.remove(seatId)
                self.refreshSeatOccupant(id: seatId)
                if let desk = self.room.childNode(withName: "seat:\(seatId)") as? DeskFurnitureNode {
                    desk.occupant.cheer()
                }
                if self.arriving.isEmpty {
                    _ = self.rebuildIfNeeded()
                }
            })

            walker.run(.sequence(actions), withKey: "walk")
            delay += 0.35
        }

        run(.sequence([
            .wait(forDuration: delay + 0.35),
            .run { [weak self] in self?.requestDoorClose() }
        ]))
    }

    // MARK: - 退室アニメーション

    private func animateDepartures(seatIds: Set<String>, repoNames: Set<String>) {
        guard !seatIds.isEmpty || !repoNames.isEmpty else { return }

        let doorFront = layout.doorFront
        let doorSpawn = layout.doorSpawn
        var delay: TimeInterval = 0.0

        for repo in repoNames {
            let nodeKey = "hub:\(repo)"
            guard let desk = room.childNode(withName: nodeKey) as? DeskFurnitureNode else { continue }
            guard !desk.occupant.isHidden else { continue }

            let walker = PersonNode(kind: .human)
            walker.setScale(1.2)
            walker.position = CGPoint(x: desk.position.x, y: desk.position.y + 30)
            walker.alpha = 0
            room.addChild(walker)
            departing[nodeKey] = walker
            walker.startBobbing()

            var actions: [SKAction] = []
            if delay > 0 { actions.append(.wait(forDuration: delay)) }
            actions.append(.run { [weak desk, weak walker] in
                walker?.alpha = 1
                desk?.occupant.isHidden = true
                desk?.bubble.run(.fadeOut(withDuration: 0.2))
                desk?.run(.sequence([
                    .wait(forDuration: 0.4),
                    .fadeOut(withDuration: 0.6)
                ]))
            })

            // 人は床を歩いて出ていく。扉に着く手前で開ける
            let waypoints = layout.departureWaypoints(from: walker.position)
            var from = walker.position
            var requestedOpen = false
            for pt in waypoints {
                if !requestedOpen && hypot(pt.x - doorFront.x, pt.y - doorFront.y) < 4 {
                    requestedOpen = true
                    actions.append(.run { [weak self] in self?.requestDoorOpen() })
                }
                let dist = hypot(pt.x - from.x, pt.y - from.y)
                guard dist > 1 else { continue }
                actions.append(.move(to: pt, duration: max(0.05, TimeInterval(dist / walkSpeed))))
                from = pt
            }
            if !requestedOpen {
                actions.append(.run { [weak self] in self?.requestDoorOpen() })
            }
            actions.append(.group([
                .move(to: doorSpawn, duration: 0.35),
                .fadeOut(withDuration: 0.35)
            ]))
            actions.append(.run { [weak self, weak walker] in
                guard let self else { return }
                walker?.stopBobbing()
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

        for seatId in seatIds {
            let nodeKey = seatId
            let desk = room.childNode(withName: "seat:\(seatId)") as? DeskFurnitureNode

            let walker: PersonNode
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
            } else if let existing = resting.removeValue(forKey: seatId)
                        ?? leavingLounge.removeValue(forKey: seatId) {
                // ラウンジで休憩している最中に終わったセッション。
                // 席を外している人は机に座っていないので、下の occupant を見る分岐では拾えない。
                // 拾い漏らすと、そのまま次の組み直しでノードごと消えて、帰らずに消えたように見える
                walker = existing
                walker.userData?.removeObject(forKey: "seat")
                walker.removeAction(forKey: "walk")
                restSeats.removeValue(forKey: seatId)
                wasSeated = false
            } else if let desk = desk, !desk.occupant.isHidden {
                let newWalker = PersonNode(kind: .agent)
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

            var actions: [SKAction] = []
            if delay > 0 { actions.append(.wait(forDuration: delay)) }

            if wasSeated {
                actions.append(.run { [weak desk, weak walker] in
                    walker?.alpha = 1
                    desk?.occupant.isHidden = true
                    desk?.hand?.isHidden = true
                    desk?.bubble.run(.fadeOut(withDuration: 0.2))
                    desk?.paper?.run(.fadeOut(withDuration: 0.2))
                    desk?.run(.sequence([
                        .wait(forDuration: 0.4),
                        .fadeOut(withDuration: 0.6)
                    ]))
                })
            } else {
                desk?.occupant.isHidden = true
                desk?.hand?.isHidden = true
                desk?.bubble.run(.fadeOut(withDuration: 0.2))
                desk?.paper?.run(.fadeOut(withDuration: 0.2))
                desk?.run(.sequence([
                    .wait(forDuration: 0.4),
                    .fadeOut(withDuration: 0.6)
                ]))
            }

            // 席を立ったら扉の正面までまっすぐ飛ぶ
            let liftOff = walker.position
            actions.append(.run { [weak self, weak walker] in
                walker?.startHovering()
                self?.requestDoorOpen()
            })
            actions.append(Self.flight(to: doorFront,
                                       distance: hypot(doorFront.x - liftOff.x,
                                                       doorFront.y - liftOff.y),
                                       speed: flySpeed))
            actions.append(.group([
                .move(to: doorSpawn, duration: 0.35),
                .fadeOut(withDuration: 0.35)
            ]))
            actions.append(.run { [weak self, weak walker] in
                guard let self else { return }
                walker?.stopBobbing()
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

    // MARK: - フレーム更新

    override func update(_ currentTime: TimeInterval) {
        for visitor in visitors.values { visitor.zPosition = -visitor.position.y }
        for visitor in returning.values { visitor.zPosition = -visitor.position.y }
        for arriver in arriving.values { arriver.zPosition = -arriver.position.y }
        for departer in departing.values { departer.zPosition = -departer.position.y }

        guard lastUpdate > 0 else {
            lastUpdate = currentTime
            cameraManager.switchedAt = currentTime
            return
        }
        let delta = min(0.25, currentTime - lastUpdate)
        lastUpdate = currentTime

        validateLayout()
        cameraManager.measureActivity(islands: islands, activity: &activity, delta: delta)
        cameraManager.reconsiderFocus(at: currentTime, islands: islands, activity: activity, layout: layout)
        cameraManager.easeCamera(camera: eye, delta: delta, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: size)
        cameraManager.placeMarkers(camera: eye, markersNode: markers, islands: islands, layout: layout, viewSize: size)
    }

    // MARK: - イベント処理

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

    private func whiteboardNode(at point: CGPoint) -> WhiteboardNode? {
        for node in nodes(at: point) {
            var current: SKNode? = node
            while let candidate = current {
                if let wb = candidate as? WhiteboardNode { return wb }
                current = candidate.parent
            }
        }
        return nil
    }

    private func refreshWhiteboards() {
        let effective = Self.effectiveSummaries(from: rateLimits)
        if effective.map(\.key) == whiteboardNodes.map(\.summary.key) {
            for (i, summary) in effective.enumerated() {
                whiteboardNodes[i].update(summary: summary)
            }
        } else {
            rebuildIfNeeded()
        }
    }

    /// 各ツールのホワイトボード表示用サマリー一覧。
    /// Claude Code と Antigravity は常に初期表示スロットを用意し、台帳到着前でも壁面にスタンバイさせる。
    static func effectiveSummaries(from summaries: [AgentQuotaSummary]) -> [AgentQuotaSummary] {
        var result: [AgentQuotaSummary] = []
        let defaultAgents = ["claude", "agy"]
        for agent in defaultAgents {
            if let existing = summaries.first(where: { $0.agent == agent }) {
                result.append(existing)
            } else {
                result.append(AgentQuotaSummary(agent: agent, rateLimits: AgentRateLimits()))
            }
        }
        for s in summaries {
            if !result.contains(where: { $0.key == s.key }) {
                result.append(s)
            }
        }
        return result
    }

    private func userInteracted() {
        cameraManager.isUserControlling = true
        cameraManager.lastUserControlTime = lastUpdate > 0 ? lastUpdate : CACurrentMediaTime()
    }

    private func loadSavedZoom() {
        guard let key = persistenceKey else { return }
        let userDefaultsKey = "\(key).zoom"
        if let savedObj = UserDefaults.standard.object(forKey: userDefaultsKey) as? Double {
            let saved = CGFloat(savedObj)
            let clamped = min(max(saved, cameraManager.minZoom), cameraManager.maxZoom)
            cameraManager.currentZoom = clamped
            cameraManager.targetZoom = clamped
            eye.setScale(clamped)
            if size.width > 0 && size.height > 0 {
                cameraManager.focus = cameraManager.clampCamera(cameraManager.focus, zoom: clamped, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: size)
                eye.position = cameraManager.focus
            }
        }
    }

    private func saveCurrentZoom() {
        guard let key = persistenceKey else { return }
        UserDefaults.standard.set(Double(cameraManager.targetZoom), forKey: "\(key).zoom")
    }

    private func applyZoom(factor: CGFloat, anchorInScene: CGPoint) {
        userInteracted()
        let newZoom = min(max(cameraManager.currentZoom * factor, cameraManager.minZoom), cameraManager.maxZoom)
        guard abs(newZoom - cameraManager.currentZoom) > 0.0001 else { return }

        let zoomRatio = newZoom / cameraManager.currentZoom
        let newFocus = CGPoint(
            x: anchorInScene.x - (anchorInScene.x - cameraManager.focus.x) * zoomRatio,
            y: anchorInScene.y - (anchorInScene.y - cameraManager.focus.y) * zoomRatio
        )
        cameraManager.currentZoom = newZoom
        cameraManager.targetZoom = newZoom
        eye.setScale(cameraManager.currentZoom)
        cameraManager.focus = cameraManager.clampCamera(newFocus, zoom: cameraManager.currentZoom, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: size)
        eye.position = cameraManager.focus
        saveCurrentZoom()
    }

    override func mouseDown(with event: NSEvent) {
        let point = event.location(in: self)

        if let clicked = whiteboardNode(at: point) {
            for wb in whiteboardNodes {
                if wb === clicked {
                    wb.toggleDetail()
                } else {
                    wb.closeDetail()
                }
            }
            return
        } else {
            for wb in whiteboardNodes {
                wb.closeDetail()
            }
        }

        let clickedSeat = seatId(at: point)

        if event.clickCount == 2 {
            if let clickedSeat {
                onOpen?(clickedSeat)
            } else {
                cameraManager.targetZoom = 1.0
                cameraManager.isUserControlling = false
                cameraManager.lastFollowedCurrentPoint = nil
                saveCurrentZoom()
            }
            return
        }

        cameraManager.dragStartInWindow = event.locationInWindow
        cameraManager.dragStartFocus = cameraManager.focus
        cameraManager.isDragging = false
        cameraManager.clickedSeatId = clickedSeat
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startInWindow = cameraManager.dragStartInWindow,
              let startFocus = cameraManager.dragStartFocus else { return }
        let currentInWindow = event.locationInWindow
        let dx = currentInWindow.x - startInWindow.x
        let dy = currentInWindow.y - startInWindow.y
        let distance = hypot(dx, dy)

        if !cameraManager.isDragging && distance > 4 {
            cameraManager.isDragging = true
            NSCursor.closedHand.push()
        }

        guard cameraManager.isDragging else { return }
        userInteracted()

        let newFocus = CGPoint(
            x: startFocus.x - dx * cameraManager.currentZoom,
            y: startFocus.y - dy * cameraManager.currentZoom
        )
        cameraManager.focus = cameraManager.clampCamera(newFocus, zoom: cameraManager.currentZoom, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: size)
        eye.position = cameraManager.focus
    }

    override func mouseUp(with event: NSEvent) {
        if cameraManager.isDragging {
            NSCursor.pop()
            cameraManager.isDragging = false
        } else if let seatId = cameraManager.clickedSeatId {
            onOpen?(seatId)
            if let spot = findSeatPoint(id: seatId) {
                cameraManager.focus = spot.point
                cameraManager.focusedIsland = spot.island
                cameraManager.switchedAt = lastUpdate
                cameraManager.isUserControlling = false
                cameraManager.lastFollowedCurrentPoint = spot.point
            }
        }
        cameraManager.dragStartInWindow = nil
        cameraManager.dragStartFocus = nil
        cameraManager.clickedSeatId = nil
    }

    private func findSeatPoint(id: String) -> (island: Int, point: CGPoint)? {
        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.id == id {
                return (index, layout.seatPoint(island: index, index: slot))
            }
        }
        return nil
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
            guard abs(deltaY) > 0.01 else { return }
            let factor = pow(1.003, -deltaY)
            let anchor = event.location(in: self)
            applyZoom(factor: factor, anchorInScene: anchor)
        } else {
            let deltaX = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.deltaX * 20
            let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 20
            guard abs(deltaX) > 0.1 || abs(deltaY) > 0.1 else { return }
            userInteracted()
            let newFocus = CGPoint(
                x: cameraManager.focus.x - deltaX * cameraManager.currentZoom,
                y: cameraManager.focus.y - deltaY * cameraManager.currentZoom
            )
            cameraManager.focus = cameraManager.clampCamera(newFocus, zoom: cameraManager.currentZoom, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: size)
            eye.position = cameraManager.focus
        }
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 / (1.0 + event.magnification)
        let anchor = event.location(in: self)
        applyZoom(factor: factor, anchorInScene: anchor)
    }
}
