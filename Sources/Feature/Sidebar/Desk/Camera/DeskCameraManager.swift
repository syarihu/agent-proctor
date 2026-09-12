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

    /// 画面外からの呼び出し吹き出しの外形パス
    static func callingBubblePath(width: CGFloat, height: CGFloat, isDown: Bool) -> CGPath {
        let path = CGMutablePath()
        let hw = width / 2
        let r: CGFloat = 10
        let tailW: CGFloat = 9
        let tailH: CGFloat = 7

        if isDown {
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

    /// 画面外で助けを求めているエージェントの呼び出し吹き出しノード
    static func createCallingBubbleNode(seat: DeskSeat, isDown: Bool, width: CGFloat) -> SKNode {
        let node = SKNode()
        node.name = "seat:\(seat.id)"

        let bubbleHeight: CGFloat = 34
        let path = callingBubblePath(width: width, height: bubbleHeight, isDown: isDown)
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

        var leftX: CGFloat = -width / 2 + 14

        if let tabNumber = seat.tabNumber {
            let badge = SKNode()
            badge.name = "seat:\(seat.id)"
            badge.position = CGPoint(x: leftX + 13, y: bubbleHeight / 2)

            let badgeBg = SKShapeNode(rect: CGRect(x: -13, y: -8, width: 26, height: 16), cornerRadius: 4.0)
            badgeBg.name = "seat:\(seat.id)"
            badgeBg.fillColor = callingBadgeBgColor
            badgeBg.strokeColor = callingBadgeStrokeColor
            badgeBg.lineWidth = 1.0
            badge.addChild(badgeBg)

            let badgeLabel = SKLabelNode(fontNamed: "SFMono-Bold")
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
        hand.position = CGPoint(x: leftX + 10, y: bubbleHeight / 2 - 8)
        hand.run(.repeatForever(.sequence([
            .rotate(toAngle: 0.22, duration: 0.35),
            .rotate(toAngle: -0.15, duration: 0.35),
        ])), withKey: "wave")
        node.addChild(hand)
        leftX += 22

        let label = SKLabelNode(fontNamed: "SFMono-Bold")
        label.name = "seat:\(seat.id)"
        label.fontSize = 11.0
        label.fontColor = .labelColor
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: leftX, y: bubbleHeight / 2)
        let maxChars = seat.tabNumber != nil ? 18 : 22
        label.text = SpeechBubbleNode.truncateScreenText(seat.name, limit: maxChars)
        node.addChild(label)

        let arrow = SKLabelNode(fontNamed: "SFMono-Bold")
        arrow.name = "seat:\(seat.id)"
        arrow.fontSize = 10.0
        arrow.fontColor = callingBadgeStrokeColor
        arrow.horizontalAlignmentMode = .center
        arrow.verticalAlignmentMode = .center
        arrow.position = CGPoint(x: width / 2 - 14, y: bubbleHeight / 2)
        arrow.text = isDown ? "▼" : "▲"
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

    /// 画面外の要確認吹き出しを更新配置する
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
        let step: CGFloat = (bubbleHeight + 10) * bubbleScale

        var offscreenCalling: [(seat: DeskSeat, isDown: Bool, distance: CGFloat)] = []
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

                let isDown: Bool
                if bubbleBottom < viewportBottom || point.y < viewportBottom {
                    isDown = true
                } else if bubbleTop > viewportTop || point.y > viewportTop {
                    isDown = false
                } else {
                    isDown = point.y < camera.position.y
                }
                let distance = abs(point.y - camera.position.y)
                offscreenCalling.append((seat, isDown, distance))
            }
        }

        let downCalling = offscreenCalling.filter { $0.isDown }.sorted { $0.distance < $1.distance }.prefix(2)
        let upCalling = offscreenCalling.filter { !$0.isDown }.sorted { $0.distance < $1.distance }.prefix(2)

        var needed: [(key: String, seat: DeskSeat, isDown: Bool, baseY: CGFloat)] = []

        for (idx, item) in downCalling.enumerated() {
            let key = "down:\(item.seat.id)"
            let baseY = -halfH + 6 + tailH * bubbleScale + CGFloat(idx) * step
            needed.append((key, item.seat, true, baseY))
        }

        for (idx, item) in upCalling.enumerated() {
            let key = "up:\(item.seat.id)"
            let baseY = halfH - 6 - (bubbleHeight + tailH) * bubbleScale - CGFloat(idx) * step
            needed.append((key, item.seat, false, baseY))
        }

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
                let bubble = Self.createCallingBubbleNode(seat: item.seat, isDown: item.isDown, width: baseBubbleWidth)
                markersNode.addChild(bubble)
                let newEntry = MarkerEntry(node: bubble, name: item.seat.name, tabNumber: item.seat.tabNumber)
                activeMarkers[item.key] = newEntry
                entry = newEntry
            }

            entry.node.setScale(bubbleScale)
            entry.node.position = CGPoint(x: 0, y: item.baseY)
        }
    }
}
