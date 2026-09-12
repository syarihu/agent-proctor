import AppKit
import Foundation
import SpriteKit

/// 頭上に浮かべる思考雲（タスク内容またはリポジトリ名を表示する）ノード。
///
/// 喋っている吹き出しではなく「頭の中にタスクを思い浮かべている」雲の形をしている。
/// iTerm2 でアクティブなタブ番号（⌘1 など）バッジの表示や、現在作業中タブのハイライトにも対応する。
final class SpeechBubbleNode: SKNode {
    let isHub: Bool
    let shape: SKShapeNode
    let label: SKLabelNode
    var tabBadge: SKNode?
    var tabBadgeBg: SKShapeNode?
    var tabBadgeLabel: SKLabelNode?

    init(isHub: Bool, initialText: String) {
        self.isHub = isHub

        let width: CGFloat = isHub ? 210 : 222
        let height: CGFloat = isHub ? 34 : 28
        let fontSize: CGFloat = isHub ? 13.2 : 11.3
        let limit = isHub ? 22 : 30
        let bubbleY: CGFloat = 70

        let shapePath = Self.thoughtBubblePath(width: width, height: height, bulge: isHub ? 3.4 : 3.0)
        shape = SKShapeNode(path: shapePath)
        shape.name = "bubbleShape"
        shape.position = CGPoint(x: 0, y: bubbleY)
        shape.fillColor = Self.bubbleFillColor(isHub: isHub, isCurrent: false)
        shape.strokeColor = isHub
            ? .secondaryLabelColor.withAlphaComponent(0.55)
            : .secondaryLabelColor.withAlphaComponent(0.35)
        shape.lineWidth = isHub ? 1.0 : 0.8

        label = SKLabelNode(fontNamed: "SFMono-Bold")
        label.name = "bubbleLabel"
        label.fontSize = fontSize
        label.fontColor = .labelColor
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: bubbleY + height / 2)
        label.text = Self.truncateScreenText(initialText, limit: limit)

        super.init()
        name = "speechBubble"

        addChild(shape)

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
            addChild(dot)
        }

        addChild(label)

        if !isHub {
            // タブ番号バッジ（⌘1など）。思考雲の左上角に乗せる
            let badge = SKNode()
            badge.name = "tabBadge"
            badge.position = CGPoint(x: -width / 2 + 18, y: bubbleY + height - 1)
            badge.zPosition = 10
            badge.isHidden = true

            let colors = Self.tabBadgeColors(isCurrent: false)
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

            addChild(badge)
            self.tabBadge = badge
            self.tabBadgeBg = badgeBg
            self.tabBadgeLabel = badgeLabel
        }

        // 吹き出しは頭上に浮かぶ要素のため、床を歩く人間や机よりも必ず手前に描画する
        zPosition = 5000
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// テキスト・枠線色・アクティブ状態・タブ番号を更新する
    func update(text: String, isCurrent: Bool, tabNumber: Int?, strokeColor: NSColor) {
        let limit = isHub ? 22 : 30
        label.text = Self.truncateScreenText(text, limit: limit)

        shape.strokeColor = strokeColor
        shape.fillColor = Self.bubbleFillColor(isHub: isHub, isCurrent: isCurrent)

        // しっぽの泡も色を同期
        for child in children {
            if child.name?.hasPrefix("trailDot") == true, let dot = child as? SKShapeNode {
                dot.fillColor = shape.fillColor
                dot.strokeColor = shape.strokeColor
            }
        }

        // タブバッジの更新
        if let badge = tabBadge, let badgeBg = tabBadgeBg, let badgeLabel = tabBadgeLabel {
            if let tabNumber = tabNumber, tabNumber > 0 {
                badge.isHidden = false
                let colors = Self.tabBadgeColors(isCurrent: isCurrent)
                badgeBg.fillColor = colors.bg
                badgeBg.strokeColor = colors.stroke
                badgeBg.lineWidth = colors.width
                badgeLabel.fontColor = colors.text
                badgeLabel.text = "⌘\(tabNumber)"
            } else {
                badge.isHidden = true
            }
        }
    }

    // MARK: - パス生成と装飾

    /// 思い出している風の思考雲の外形パス。
    /// 喋っている吹き出しではなく、頭の中にタスク内容を思い浮かべている雲の形にする
    static func thoughtBubblePath(width: CGFloat, height: CGFloat, bulge: CGFloat = 3.2) -> CGPath {
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

    /// 思考雲の背景色
    static func bubbleFillColor(isHub: Bool, isCurrent: Bool) -> NSColor {
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

    /// タブ番号バッジの色
    static func tabBadgeColors(isCurrent: Bool) -> (bg: NSColor, stroke: NSColor, text: NSColor, width: CGFloat) {
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
                        : NSColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 0.95)
                },
                stroke: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.50, alpha: 0.40)
                        : NSColor(white: 0.50, alpha: 0.35)
                },
                text: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor(white: 0.75, alpha: 0.9)
                        : NSColor(white: 0.35, alpha: 0.9)
                },
                width: 0.8
            )
        }
    }

    /// 画面幅に収まるよう文字数を切り詰める
    static func truncateScreenText(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}
