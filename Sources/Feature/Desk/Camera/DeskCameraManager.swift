import AppKit
import Foundation
import Model
import SpriteKit

/// オフィス見取り図のカメラ（視点追従・ズーム・パン・画面外呼び出し吹き出し）を管理するクラス。
final class DeskCameraManager {
    // MARK: - ズーム定数と状態

    let minZoom: CGFloat = 0.45
    let maxZoom: CGFloat = 2.4
    var currentZoom: CGFloat = 1.0
    var targetZoom: CGFloat = 1.0

    // MARK: - 追従とフォーカス状態

    var focus: CGPoint = .zero
    var focusedIsland: Int = 0
    var switchedAt: TimeInterval = 0
    let dwell: TimeInterval = 8
    let switchMargin: Double = 1.4

    var isUserControlling = false
    var lastUserControlTime: TimeInterval = 0
    var lastFollowedCurrentPoint: CGPoint?

    // MARK: - ドラッグ操作状態

    var dragStartInWindow: CGPoint?
    var dragStartFocus: CGPoint?
    var isDragging = false
    var clickedSeatId: String?

    // MARK: - 画面外呼び出しマーカー

    var activeMarkers: [String: MarkerEntry] = [:]

    // MARK: - カメラ移動とクランプ

    /// カメラが部屋の外側を映しすぎないよう、壁の内側に収める
    func clampCamera(_ point: CGPoint, zoom: CGFloat, roomWidth: CGFloat, roomHeight: CGFloat, viewSize: CGSize) -> CGPoint {
        let viewW = viewSize.width * zoom
        let viewH = viewSize.height * zoom
        func fit(_ value: CGFloat, room: CGFloat, view: CGFloat) -> CGFloat {
            guard room > view else { return room / 2 }
            return min(max(value, view / 2), room - view / 2)
        }
        return CGPoint(x: fit(point.x, room: roomWidth, view: viewW),
                       y: fit(point.y, room: roomHeight, view: viewH))
    }

    /// カメラの位置とズーム率を滑らかに補間する
    func easeCamera(camera: SKCameraNode, delta: TimeInterval, roomWidth: CGFloat, roomHeight: CGFloat, viewSize: CGSize) {
        let zoomFactor = 1 - pow(0.04, delta)
        currentZoom += (targetZoom - currentZoom) * zoomFactor
        camera.setScale(currentZoom)

        let targetPos = clampCamera(focus, zoom: currentZoom, roomWidth: roomWidth, roomHeight: roomHeight, viewSize: viewSize)
        let posFactor = 1 - pow(0.015, delta)
        camera.position = CGPoint(
            x: camera.position.x + (targetPos.x - camera.position.x) * posFactor,
            y: camera.position.y + (targetPos.y - camera.position.y) * posFactor
        )
    }

    // MARK: - 稼働量とフォーカス選定

    /// 島ごとの稼働量を減衰平均で計測する
    func measureActivity(islands: [DeskIsland], activity: inout [Double], delta: TimeInterval) {
        guard activity.count == islands.count else { return }
        let ratio = 1 - pow(0.5, delta / 4)
        for (index, island) in islands.enumerated() {
            let running = Double(island.seats.filter { $0.status == TaskStatus.running }.count)
            activity[index] += (running - activity[index]) * ratio
        }
    }

    /// カメラをどこに置くかを選び直す
    func reconsiderFocus(at now: TimeInterval, islands: [DeskIsland], activity: [Double], layout: DeskLayout) {
        // 1. 人間がいま見ているタブがあれば、その机を最優先で映す
        if let current = firstCurrentSeat(islands: islands, layout: layout) {
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

        // 2. ユーザーが手動で操作している最中は自動追従しない
        if isUserControlling {
            if now - lastUserControlTime >= 6.0 {
                isUserControlling = false
            }
            return
        }

        // 3. 人の手が要る机があればそこへ寄せる
        for (index, island) in islands.enumerated() {
            if let seatIndex = island.seats.firstIndex(where: { $0.needsPerson }) {
                let spot = layout.chairSpot(island: index, seat: seatIndex)
                if focusedIsland != index || focus != spot {
                    focusedIsland = index
                    focus = spot
                    switchedAt = now
                }
                return
            }
        }

        // 4. 動いているセッションが無ければ hub に戻す
        if activity.allSatisfy({ $0 < 0.05 }) {
            if focusedIsland != 0 {
                focusedIsland = 0
                focus = layout.hubPoint(island: 0)
                switchedAt = now
            }
            return
        }

        guard now - switchedAt >= dwell else { return }

        // 5. 最も忙しい島へカメラを向ける
        let currentLoad = activity.indices.contains(focusedIsland) ? activity[focusedIsland] : 0
        var bestIndex = focusedIsland
        var bestLoad = currentLoad
        for (index, load) in activity.enumerated() {
            if load > bestLoad * switchMargin {
                bestLoad = load
                bestIndex = index
            }
        }
        if bestIndex != focusedIsland {
            focusedIsland = bestIndex
            focus = layout.hubPoint(island: bestIndex)
            switchedAt = now
        }
    }

    private func firstCurrentSeat(islands: [DeskIsland], layout: DeskLayout) -> (island: Int, point: CGPoint)? {
        for (index, island) in islands.enumerated() {
            if let seatIndex = island.seats.firstIndex(where: { $0.isCurrent }) {
                return (index, layout.chairSpot(island: index, seat: seatIndex))
            }
        }
        return nil
    }

    // MARK: - 画面外呼び出し吹き出しの配置

    /// 画面外からの呼び出し吹き出しの外形パス（四方向の矢印尾っぽに対応）
    static func callingBubblePath(width: CGFloat, height: CGFloat, direction: CallingDirection) -> CGPath {
        let path = CGMutablePath()
        let hw = width / 2
        let hh = height / 2
        let r: CGFloat = 10
        let tailW: CGFloat = 9
        let tailH: CGFloat = 7

        switch direction {
        case .bottom:
            path.move(to: CGPoint(x: -hw + r, y: -hh))
            path.addLine(to: CGPoint(x: -tailW, y: -hh))
            path.addLine(to: CGPoint(x: 0, y: -hh - tailH))
            path.addLine(to: CGPoint(x: tailW, y: -hh))
            path.addLine(to: CGPoint(x: hw - r, y: -hh))
            path.addArc(tangent1End: CGPoint(x: hw, y: -hh), tangent2End: CGPoint(x: hw, y: -hh + r), radius: r)
            path.addLine(to: CGPoint(x: hw, y: hh - r))
            path.addArc(tangent1End: CGPoint(x: hw, y: hh), tangent2End: CGPoint(x: hw - r, y: hh), radius: r)
            path.addLine(to: CGPoint(x: -hw + r, y: hh))
            path.addArc(tangent1End: CGPoint(x: -hw, y: hh), tangent2End: CGPoint(x: -hw, y: hh - r), radius: r)
            path.addLine(to: CGPoint(x: -hw, y: -hh + r))
            path.addArc(tangent1End: CGPoint(x: -hw, y: -hh), tangent2End: CGPoint(x: -hw + r, y: -hh), radius: r)
            path.closeSubpath()

        case .top:
            path.move(to: CGPoint(x: -hw + r, y: -hh))
            path.addLine(to: CGPoint(x: hw - r, y: -hh))
            path.addArc(tangent1End: CGPoint(x: hw, y: -hh), tangent2End: CGPoint(x: hw, y: -hh + r), radius: r)
            path.addLine(to: CGPoint(x: hw, y: hh - r))
            path.addArc(tangent1End: CGPoint(x: hw, y: hh), tangent2End: CGPoint(x: hw - r, y: hh), radius: r)
            path.addLine(to: CGPoint(x: tailW, y: hh))
            path.addLine(to: CGPoint(x: 0, y: hh + tailH))
            path.addLine(to: CGPoint(x: -tailW, y: hh))
            path.addLine(to: CGPoint(x: -hw + r, y: hh))
            path.addArc(tangent1End: CGPoint(x: -hw, y: hh), tangent2End: CGPoint(x: -hw, y: hh - r), radius: r)
            path.addLine(to: CGPoint(x: -hw, y: -hh + r))
            path.addArc(tangent1End: CGPoint(x: -hw, y: -hh), tangent2End: CGPoint(x: -hw + r, y: -hh), radius: r)
            path.closeSubpath()

        case .left:
            path.move(to: CGPoint(x: -hw + r, y: -hh))
            path.addLine(to: CGPoint(x: hw - r, y: -hh))
            path.addArc(tangent1End: CGPoint(x: hw, y: -hh), tangent2End: CGPoint(x: hw, y: -hh + r), radius: r)
            path.addLine(to: CGPoint(x: hw, y: hh - r))
            path.addArc(tangent1End: CGPoint(x: hw, y: hh), tangent2End: CGPoint(x: hw - r, y: hh), radius: r)
            path.addLine(to: CGPoint(x: -hw + r, y: hh))
            path.addArc(tangent1End: CGPoint(x: -hw, y: hh), tangent2End: CGPoint(x: -hw, y: hh - r), radius: r)
            path.addLine(to: CGPoint(x: -hw, y: tailW))
            path.addLine(to: CGPoint(x: -hw - tailH, y: 0))
            path.addLine(to: CGPoint(x: -hw, y: -tailW))
            path.addLine(to: CGPoint(x: -hw, y: -hh + r))
            path.addArc(tangent1End: CGPoint(x: -hw, y: -hh), tangent2End: CGPoint(x: -hw + r, y: -hh), radius: r)
            path.closeSubpath()

        case .right:
            path.move(to: CGPoint(x: -hw + r, y: -hh))
            path.addLine(to: CGPoint(x: hw - r, y: -hh))
            path.addArc(tangent1End: CGPoint(x: hw, y: -hh), tangent2End: CGPoint(x: hw, y: -hh + r), radius: r)
            path.addLine(to: CGPoint(x: hw, y: -tailW))
            path.addLine(to: CGPoint(x: hw + tailH, y: 0))
            path.addLine(to: CGPoint(x: hw, y: tailW))
            path.addLine(to: CGPoint(x: hw, y: hh - r))
            path.addArc(tangent1End: CGPoint(x: hw, y: hh), tangent2End: CGPoint(x: hw - r, y: hh), radius: r)
            path.addLine(to: CGPoint(x: -hw + r, y: hh))
            path.addArc(tangent1End: CGPoint(x: -hw, y: hh), tangent2End: CGPoint(x: -hw, y: hh - r), radius: r)
            path.addLine(to: CGPoint(x: -hw, y: -hh + r))
            path.addArc(tangent1End: CGPoint(x: -hw, y: -hh), tangent2End: CGPoint(x: -hw + r, y: -hh), radius: r)
            path.closeSubpath()
        }
        return path
    }

    /// 画面外で助けを求めているエージェントの呼び出し吹き出しノード
    static func createCallingBubbleNode(seat: DeskSeat, direction: CallingDirection, width: CGFloat) -> SKNode {
        let node = SKNode()
        node.name = "seat:\(seat.id)"

        let bubbleHeight: CGFloat = 34
        let path = callingBubblePath(width: width, height: bubbleHeight, direction: direction)
        let shape = SKShapeNode(path: path)
        shape.name = "seat:\(seat.id)"
        shape.fillColor = callingBubbleFillColor
        shape.strokeColor = callingBubbleStrokeColor
        shape.lineWidth = 1.4
        node.addChild(shape)

        shape.run(.repeatForever(.sequence([
            .scale(to: 1.025, duration: 0.6),
            .scale(to: 1.0, duration: 0.6),
        ])), withKey: "pulse")

        var leftX: CGFloat
        let arrowX: CGFloat
        let arrowText: String

        switch direction {
        case .left:
            arrowText = "◀"
            arrowX = -width / 2 + 13
            leftX = -width / 2 + 25
        case .right:
            arrowText = "▶"
            arrowX = width / 2 - 13
            leftX = -width / 2 + 14
        case .top:
            arrowText = "▲"
            arrowX = width / 2 - 14
            leftX = -width / 2 + 14
        case .bottom:
            arrowText = "▼"
            arrowX = width / 2 - 14
            leftX = -width / 2 + 14
        }

        if let tabNumber = seat.tabNumber {
            let badge = SKNode()
            badge.name = "seat:\(seat.id)"
            badge.position = CGPoint(x: leftX + 13, y: 0)

            let badgeBg = SKShapeNode(rect: CGRect(x: -13, y: -8, width: 26, height: 16), cornerRadius: 4.0)
            badgeBg.name = "seat:\(seat.id)"
            badgeBg.fillColor = callingBadgeBgColor
            badgeBg.strokeColor = callingBadgeStrokeColor
            badgeBg.lineWidth = 1.0
            badge.addChild(badgeBg)

            let badgeLabel = SKLabelNode(fontNamed: "Menlo-Bold")
            badgeLabel.name = "seat:\(seat.id)"
            badgeLabel.fontSize = 9.0
            badgeLabel.fontColor = callingBadgeTextColor
            badgeLabel.horizontalAlignmentMode = .center
            badgeLabel.verticalAlignmentMode = .center
            badgeLabel.text = "⌘\(tabNumber)"
            badge.addChild(badgeLabel)

            node.addChild(badge)
            leftX += 32
        }

        let hand = DeskFurnitureNode.createHandMark()
        hand.name = "seat:\(seat.id)"
        hand.setScale(0.85)
        hand.position = CGPoint(x: leftX + 10, y: -8)
        hand.run(.repeatForever(.sequence([
            .rotate(toAngle: 0.22, duration: 0.35),
            .rotate(toAngle: -0.15, duration: 0.35),
        ])), withKey: "wave")
        node.addChild(hand)
        leftX += 22

        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.name = "seat:\(seat.id)"
        label.fontSize = 11.0
        label.fontColor = .labelColor
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: leftX, y: 0)
        let maxChars = (seat.tabNumber != nil || direction == .left) ? 17 : 21
        label.text = SpeechBubbleNode.truncateScreenText(seat.name, limit: maxChars)
        node.addChild(label)

        let arrow = SKLabelNode(fontNamed: "Menlo-Bold")
        arrow.name = "seat:\(seat.id)"
        arrow.fontSize = 10.0
        arrow.fontColor = callingBadgeStrokeColor
        arrow.horizontalAlignmentMode = .center
        arrow.verticalAlignmentMode = .center
        arrow.position = CGPoint(x: arrowX, y: 0)
        arrow.text = arrowText
        node.addChild(arrow)

        node.zPosition = 10000
        return node
    }

    static let callingBubbleFillColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.22, green: 0.16, blue: 0.10, alpha: 0.98)
            : NSColor(red: 1.0, green: 0.96, blue: 0.90, alpha: 0.98)
    }

    static let callingBubbleStrokeColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.98, green: 0.58, blue: 0.18, alpha: 0.95)
            : NSColor(red: 0.92, green: 0.46, blue: 0.08, alpha: 0.95)
    }

    static let callingBadgeBgColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.20, blue: 0.08, alpha: 0.98)
            : NSColor(red: 0.98, green: 0.90, blue: 0.80, alpha: 0.98)
    }

    static let callingBadgeStrokeColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.98, green: 0.60, blue: 0.15, alpha: 1.0)
            : NSColor(red: 0.90, green: 0.45, blue: 0.05, alpha: 1.0)
    }

    static let callingBadgeTextColor: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.75, blue: 0.30, alpha: 1.0)
            : NSColor(red: 0.75, green: 0.32, blue: 0.02, alpha: 1.0)
    }

    /// 画面外の要確認吹き出しを更新配置する。
    /// 助けを求めているエージェントがいる方角（上下左右）の画面端から吹き出しを出現させ、
    /// 矢印と尾っぽでその方角を指し示す
    func placeMarkers(camera: SKCameraNode, markersNode: SKNode, islands: [DeskIsland], layout: DeskLayout, viewSize: CGSize) {
        guard viewSize.width >= 100 && viewSize.height >= 80 else {
            if !activeMarkers.isEmpty {
                markersNode.removeAllChildren()
                activeMarkers.removeAll()
            }
            return
        }

        let halfW = viewSize.width / 2
        let halfH = viewSize.height / 2
        let sceneHalfW = halfW * currentZoom
        let sceneHalfH = halfH * currentZoom

        let viewportLeft = camera.position.x - sceneHalfW
        let viewportRight = camera.position.x + sceneHalfW
        let viewportBottom = camera.position.y - sceneHalfH
        let viewportTop = camera.position.y + sceneHalfH

        let baseBubbleWidth: CGFloat = 236
        let maxScale = max(0.45, (viewSize.width - 24) / baseBubbleWidth)
        let bubbleScale = min(maxScale, max(0.42, 1.0 / currentZoom))
        let bubbleHeight: CGFloat = 34
        let tailH: CGFloat = 7

        let effectiveBubbleW = baseBubbleWidth * bubbleScale
        let effectiveBubbleH = bubbleHeight * bubbleScale
        let padding: CGFloat = 8

        let maxX = max(0, halfW - effectiveBubbleW / 2 - padding - tailH * bubbleScale)
        let maxY = max(0, halfH - effectiveBubbleH / 2 - padding - tailH * bubbleScale)

        struct CallingItem {
            let seat: DeskSeat
            let direction: CallingDirection
            let targetPos: CGPoint
            let distance: CGFloat
        }

        var offscreenItems: [CallingItem] = []

        for (index, island) in islands.enumerated() {
            for (slot, seat) in island.seats.enumerated() where seat.needsPerson {
                let point = layout.seatPoint(island: index, index: slot)
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

                // カメラ中心からの画面上の相対ベクトル（ポイント単位）
                let dx = (point.x - camera.position.x) / currentZoom
                let dy = (point.y - camera.position.y) / currentZoom

                // 画面端の境界矩形とのレイ交差から、上下左右いずれの縁から出すかを判定
                let tx = (abs(dx) > 0.001) ? maxX / abs(dx) : CGFloat.infinity
                let ty = (abs(dy) > 0.001) ? maxY / abs(dy) : CGFloat.infinity

                let direction: CallingDirection
                let pos: CGPoint

                if ty < tx {
                    // 上端または下端の境界に先に到達
                    if dy > 0 {
                        direction = .top
                        let x = min(max(dx * ty, -maxX), maxX)
                        pos = CGPoint(x: x, y: maxY)
                    } else {
                        direction = .bottom
                        let x = min(max(dx * ty, -maxX), maxX)
                        pos = CGPoint(x: x, y: -maxY)
                    }
                } else {
                    // 左端または右端の境界に先に到達
                    if dx < 0 {
                        direction = .left
                        let y = min(max(dy * tx, -maxY), maxY)
                        pos = CGPoint(x: -maxX, y: y)
                    } else {
                        direction = .right
                        let y = min(max(dy * tx, -maxY), maxY)
                        pos = CGPoint(x: maxX, y: y)
                    }
                }

                let distance = hypot(dx, dy)
                offscreenItems.append(CallingItem(seat: seat, direction: direction, targetPos: pos, distance: distance))
            }
        }

        // 近い順に最大3件まで表示
        let visibleItems = offscreenItems.sorted { $0.distance < $1.distance }.prefix(3)

        // 各方角ごとに吹き出しの重なりを解消して配置を決定する
        var itemsByDirection: [CallingDirection: [CallingItem]] = [:]
        for item in visibleItems {
            itemsByDirection[item.direction, default: []].append(item)
        }

        var needed: [(seat: DeskSeat, direction: CallingDirection, targetPos: CGPoint)] = []

        for (direction, items) in itemsByDirection {
            guard !items.isEmpty else { continue }
            if items.count == 1 {
                needed.append((items[0].seat, direction, items[0].targetPos))
                continue
            }

            switch direction {
            case .left, .right:
                // 縦の縁では Y 座標（上下）に分散させて重なりを防ぎ、尾っぽは画面端に密着させる
                var sorted = items.sorted { $0.targetPos.y < $1.targetPos.y }
                let minGap = effectiveBubbleH + 8
                for i in 1..<sorted.count {
                    if sorted[i].targetPos.y - sorted[i - 1].targetPos.y < minGap {
                        let shift = minGap - (sorted[i].targetPos.y - sorted[i - 1].targetPos.y)
                        sorted[i] = CallingItem(
                            seat: sorted[i].seat,
                            direction: sorted[i].direction,
                            targetPos: CGPoint(x: sorted[i].targetPos.x, y: sorted[i].targetPos.y + shift),
                            distance: sorted[i].distance
                        )
                    }
                }
                // 画面上端・下端からはみ出さないよう全体を調整
                if let topY = sorted.last?.targetPos.y, topY > maxY {
                    let over = topY - maxY
                    for i in 0..<sorted.count {
                        sorted[i] = CallingItem(
                            seat: sorted[i].seat,
                            direction: sorted[i].direction,
                            targetPos: CGPoint(x: sorted[i].targetPos.x, y: max(-maxY, sorted[i].targetPos.y - over)),
                            distance: sorted[i].distance
                        )
                    }
                }
                for item in sorted {
                    needed.append((item.seat, direction, item.targetPos))
                }

            case .top, .bottom:
                // 横の縁では、画面幅に余裕があれば左右に並べ、狭ければ段重ねにする
                let minGap = effectiveBubbleW + 10
                let totalWidthNeeded = CGFloat(items.count) * effectiveBubbleW + CGFloat(items.count - 1) * 10
                if 2 * maxX >= totalWidthNeeded {
                    var sorted = items.sorted { $0.targetPos.x < $1.targetPos.x }
                    for i in 1..<sorted.count {
                        if sorted[i].targetPos.x - sorted[i - 1].targetPos.x < minGap {
                            let shift = minGap - (sorted[i].targetPos.x - sorted[i - 1].targetPos.x)
                            sorted[i] = CallingItem(
                                seat: sorted[i].seat,
                                direction: sorted[i].direction,
                                targetPos: CGPoint(x: sorted[i].targetPos.x + shift, y: sorted[i].targetPos.y),
                                distance: sorted[i].distance
                            )
                        }
                    }
                    if let rightX = sorted.last?.targetPos.x, rightX > maxX {
                        let over = rightX - maxX
                        for i in 0..<sorted.count {
                            sorted[i] = CallingItem(
                                seat: sorted[i].seat,
                                direction: sorted[i].direction,
                                targetPos: CGPoint(x: max(-maxX, sorted[i].targetPos.x - over), y: sorted[i].targetPos.y),
                                distance: sorted[i].distance
                            )
                        }
                    }
                    for item in sorted {
                        needed.append((item.seat, direction, item.targetPos))
                    }
                } else {
                    let stackStep: CGFloat = (bubbleHeight + 10) * bubbleScale
                    for (idx, item) in items.enumerated() {
                        let y = direction == .top
                            ? item.targetPos.y - CGFloat(idx) * stackStep
                            : item.targetPos.y + CGFloat(idx) * stackStep
                        needed.append((item.seat, direction, CGPoint(x: item.targetPos.x, y: y)))
                    }
                }
            }
        }

        let neededKeys = Set(needed.map { $0.seat.id })
        for (key, entry) in activeMarkers where !neededKeys.contains(key) {
            entry.node.run(.sequence([
                .fadeOut(withDuration: 0.2),
                .removeFromParent()
            ]))
            activeMarkers.removeValue(forKey: key)
        }

        for item in needed {
            let key = item.seat.id
            let entry: MarkerEntry
            if let existing = activeMarkers[key],
               existing.name == item.seat.name,
               existing.tabNumber == item.seat.tabNumber,
               existing.direction == item.direction {
                entry = existing
            } else {
                activeMarkers[key]?.node.removeFromParent()
                let bubble = Self.createCallingBubbleNode(seat: item.seat, direction: item.direction, width: baseBubbleWidth)
                markersNode.addChild(bubble)

                // 呼んでいる方向の外側から画面内へスライドインする登場演出
                let spawnOffset: CGFloat = 36 * bubbleScale
                let spawnPos: CGPoint
                switch item.direction {
                case .top:
                    spawnPos = CGPoint(x: item.targetPos.x, y: item.targetPos.y + spawnOffset)
                case .bottom:
                    spawnPos = CGPoint(x: item.targetPos.x, y: item.targetPos.y - spawnOffset)
                case .left:
                    spawnPos = CGPoint(x: item.targetPos.x - spawnOffset, y: item.targetPos.y)
                case .right:
                    spawnPos = CGPoint(x: item.targetPos.x + spawnOffset, y: item.targetPos.y)
                }
                bubble.position = spawnPos
                bubble.alpha = 0

                let moveAction = SKAction.move(to: item.targetPos, duration: 0.28)
                moveAction.timingMode = .easeOut
                let enterAction = SKAction.group([
                    .fadeIn(withDuration: 0.20),
                    moveAction
                ])
                bubble.run(enterAction, withKey: "enter")

                let newEntry = MarkerEntry(node: bubble, name: item.seat.name, tabNumber: item.seat.tabNumber, direction: item.direction)
                activeMarkers[key] = newEntry
                entry = newEntry
            }

            entry.node.setScale(bubbleScale)
            // 登場演出中以外は、カメラのパンやズームの移動に合わせて現在位置を追従させる
            if entry.node.action(forKey: "enter") == nil {
                entry.node.position = item.targetPos
            }
        }
    }
}
