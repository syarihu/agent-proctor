import AppKit
import Foundation
import Model
import SpriteKit

/// オフィス内のホワイトボード（エージェントの使用量・レートリミットを表示する）ノード。
///
/// 奥壁の人間の右側に設置され、Claude Code や Antigravity のレートリミット使用状況
/// （5時間枠・7日間枠のパーセントとミニゲージ）をホワイトボードの板書風に表示する。
/// クリックするとリセット予定時刻などの詳細吹き出しを表示する。
final class WhiteboardNode: SKNode {
    // MARK: - 寸法定数

    static let boardWidth: CGFloat = 112
    static let boardHeight: CGFloat = 60

    // MARK: - プロパティ

    private let boardNode: SKNode
    private let contentNode: SKNode
    private var detailBubble: SKNode?
    private var currentSummaries: [AgentQuotaSummary] = []
    private var isDetailOpen = false

    // MARK: - 初期化

    init(summaries: [AgentQuotaSummary]) {
        self.currentSummaries = summaries
        self.boardNode = SKNode()
        self.contentNode = SKNode()

        super.init()
        name = "whiteboard"
        zPosition = -9970

        addChild(boardNode)
        boardNode.addChild(contentNode)

        buildFrameAndAccessories()
        renderContent(summaries: summaries)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 外枠と小物の構築

    private func buildFrameAndAccessories() {
        let w = Self.boardWidth
        let h = Self.boardHeight

        // 上部の壁掛け金具（2箇所）
        for dx in [-32.0, 32.0] {
            let bracket = SKShapeNode(rect: CGRect(x: dx - 2.5, y: h / 2 - 1, width: 5, height: 4),
                                      cornerRadius: 1)
            bracket.fillColor = NSColor(white: 0.35, alpha: 0.95)
            bracket.strokeColor = .clear
            bracket.zPosition = -1
            boardNode.addChild(bracket)
        }

        // ホワイトボード本体（アルミ枠＋光沢白板）
        let board = SKShapeNode(rect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                cornerRadius: 3)
        board.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.92, alpha: 0.98)
                : NSColor(calibratedWhite: 0.97, alpha: 0.99)
        }
        board.strokeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.60, alpha: 1.0)
                : NSColor(white: 0.75, alpha: 1.0)
        }
        board.lineWidth = 1.6
        board.zPosition = 0
        boardNode.addChild(board)

        // ペン置きトレイ（下部のアルミ棚）
        let tray = SKShapeNode(rect: CGRect(x: -w / 2 + 10, y: -h / 2 - 2.5, width: w - 20, height: 2.5),
                               cornerRadius: 0.8)
        tray.fillColor = NSColor(white: 0.65, alpha: 1.0)
        tray.strokeColor = NSColor(white: 0.45, alpha: 0.8)
        tray.lineWidth = 0.6
        tray.zPosition = 2
        boardNode.addChild(tray)

        // 黒板消し（イレーザー）
        let eraser = SKShapeNode(rect: CGRect(x: -w / 2 + 14, y: -h / 2 - 1.5, width: 9, height: 3.5),
                                 cornerRadius: 0.6)
        eraser.fillColor = NSColor(white: 0.25, alpha: 0.95)
        eraser.strokeColor = .clear
        eraser.zPosition = 3
        boardNode.addChild(eraser)

        // マーカーペン3本（黒・赤・青）
        let penColors: [NSColor] = [
            NSColor(white: 0.15, alpha: 0.95),
            NSColor(red: 0.85, green: 0.20, blue: 0.20, alpha: 0.95),
            NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.95)
        ]
        for (i, color) in penColors.enumerated() {
            let pen = SKShapeNode(rect: CGRect(x: -w / 2 + 27 + CGFloat(i) * 7, y: -h / 2 - 1, width: 5, height: 1.8),
                                  cornerRadius: 0.5)
            pen.fillColor = color
            pen.strokeColor = .clear
            pen.zPosition = 3
            boardNode.addChild(pen)
        }

        // 右上の丸いマグネット
        let magnet = SKShapeNode(circleOfRadius: 2.2)
        magnet.fillColor = NSColor(red: 0.85, green: 0.25, blue: 0.25, alpha: 0.95)
        magnet.strokeColor = NSColor(white: 0.4, alpha: 0.5)
        magnet.lineWidth = 0.5
        magnet.position = CGPoint(x: w / 2 - 7, y: h / 2 - 7)
        magnet.zPosition = 4
        boardNode.addChild(magnet)
    }

    // MARK: - 板書コンテンツの描画

    func update(summaries: [AgentQuotaSummary]) {
        guard self.currentSummaries != summaries else { return }
        self.currentSummaries = summaries
        renderContent(summaries: summaries)
        if isDetailOpen {
            renderDetailBubble()
        }
    }

    private func renderContent(summaries: [AgentQuotaSummary]) {
        contentNode.removeAllChildren()
        contentNode.zPosition = 5

        let w = Self.boardWidth
        let h = Self.boardHeight

        // 見出しタイトル: "QUOTA"
        let titleLabel = SKLabelNode(fontNamed: "SFMono-Bold")
        titleLabel.fontSize = 6.2
        titleLabel.fontColor = NSColor(white: 0.32, alpha: 0.95)
        titleLabel.text = "LIMITS"
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.verticalAlignmentMode = .center
        titleLabel.position = CGPoint(x: 0, y: h / 2 - 9)
        contentNode.addChild(titleLabel)

        // 見出し下のアンダーライン
        let line = SKShapeNode(rect: CGRect(x: -w / 2 + 10, y: h / 2 - 13, width: w - 20, height: 0.6))
        line.fillColor = NSColor(white: 0.70, alpha: 0.8)
        line.strokeColor = .clear
        contentNode.addChild(line)

        if summaries.isEmpty {
            let emptyLabel = SKLabelNode(fontNamed: "SFMono-Regular")
            emptyLabel.fontSize = 6.0
            emptyLabel.fontColor = NSColor(white: 0.55, alpha: 0.9)
            emptyLabel.text = "NO LIMITS"
            emptyLabel.horizontalAlignmentMode = .center
            emptyLabel.verticalAlignmentMode = .center
            emptyLabel.position = CGPoint(x: 0, y: -2)
            contentNode.addChild(emptyLabel)
            return
        }

        // 最大2件のエージェントを表示
        let displayItems = Array(summaries.prefix(2))
        let rowYs: [CGFloat] = displayItems.count == 1 ? [-2] : [4, -13]

        for (i, summary) in displayItems.enumerated() {
            let y = rowYs[i]
            let rowNode = createRowNode(summary: summary)
            rowNode.position = CGPoint(x: 0, y: y)
            contentNode.addChild(rowNode)
        }
    }

    private func createRowNode(summary: AgentQuotaSummary) -> SKNode {
        let node = SKNode()
        let w = Self.boardWidth

        // エージェント名
        let nameLabel = SKLabelNode(fontNamed: "SFMono-Bold")
        nameLabel.fontSize = 5.8
        nameLabel.fontColor = markerColor(for: summary.agent)
        nameLabel.text = shortAgentName(summary)
        nameLabel.horizontalAlignmentMode = .left
        nameLabel.verticalAlignmentMode = .center
        nameLabel.position = CGPoint(x: -w / 2 + 8, y: 0)
        node.addChild(nameLabel)

        // 5時間枠ミニゲージ
        if let five = summary.rateLimits.fiveHour {
            let gauge = createMiniGauge(label: "5h", percent: five.usedPercent, width: 22)
            gauge.position = CGPoint(x: -3, y: 0)
            node.addChild(gauge)
        }

        // 7日間枠ミニゲージ
        if let week = summary.rateLimits.sevenDay {
            let gauge = createMiniGauge(label: "7d", percent: week.usedPercent, width: 22)
            gauge.position = CGPoint(x: 27, y: 0)
            node.addChild(gauge)
        }

        return node
    }

    private func createMiniGauge(label: String, percent: Int, width: CGFloat) -> SKNode {
        let node = SKNode()

        // ラベル ("5h" / "7d")
        let lbl = SKLabelNode(fontNamed: "SFMono-Regular")
        lbl.fontSize = 5.0
        lbl.fontColor = NSColor(white: 0.45, alpha: 0.9)
        lbl.text = label
        lbl.horizontalAlignmentMode = .right
        lbl.verticalAlignmentMode = .center
        lbl.position = CGPoint(x: -2, y: 0)
        node.addChild(lbl)

        // ゲージ背景
        let bg = SKShapeNode(rect: CGRect(x: 0, y: -2, width: width, height: 4), cornerRadius: 1)
        bg.fillColor = NSColor(white: 0.85, alpha: 0.9)
        bg.strokeColor = .clear
        node.addChild(bg)

        // ゲージの塗り
        let clamped = max(0, min(100, percent))
        let fillWidth = width * CGFloat(clamped) / 100.0
        if fillWidth > 0.5 {
            let fill = SKShapeNode(rect: CGRect(x: 0, y: -2, width: fillWidth, height: 4), cornerRadius: 1)
            fill.fillColor = gaugeColor(percent: clamped)
            fill.strokeColor = .clear
            node.addChild(fill)
        }

        // パーセント数値
        let pctLabel = SKLabelNode(fontNamed: "SFMono-Bold")
        pctLabel.fontSize = 4.8
        pctLabel.fontColor = gaugeColor(percent: clamped)
        pctLabel.text = "\(clamped)%"
        pctLabel.horizontalAlignmentMode = .left
        pctLabel.verticalAlignmentMode = .center
        pctLabel.position = CGPoint(x: width + 2, y: 0)
        node.addChild(pctLabel)

        return node
    }

    private func shortAgentName(_ summary: AgentQuotaSummary) -> String {
        switch summary.agent {
        case "claude": return "Claude"
        case "agy": return "AGY"
        case "codex": return "Codex"
        default: return String(summary.agentDisplayName.prefix(6))
        }
    }

    private func markerColor(for agent: String) -> NSColor {
        switch agent {
        case "claude":
            return NSColor(red: 0.75, green: 0.38, blue: 0.12, alpha: 0.95) // 手書き風アンバー
        case "agy":
            return NSColor(red: 0.25, green: 0.38, blue: 0.80, alpha: 0.95) // インディゴ
        case "codex":
            return NSColor(red: 0.15, green: 0.60, blue: 0.38, alpha: 0.95) // グリーン
        default:
            return NSColor(white: 0.25, alpha: 0.95)
        }
    }

    private func gaugeColor(percent: Int) -> NSColor {
        if percent >= 90 {
            return NSColor(red: 0.85, green: 0.20, blue: 0.20, alpha: 0.95)
        } else if percent >= 70 {
            return NSColor(red: 0.88, green: 0.52, blue: 0.12, alpha: 0.95)
        } else {
            return NSColor(red: 0.18, green: 0.65, blue: 0.28, alpha: 0.95)
        }
    }

    // MARK: - クリック時の詳細吹き出し

    func toggleDetail() {
        if isDetailOpen {
            closeDetail()
        } else {
            openDetail()
        }
    }

    private func openDetail() {
        isDetailOpen = true
        renderDetailBubble()
    }

    func closeDetail() {
        isDetailOpen = false
        detailBubble?.run(.sequence([
            .fadeOut(withDuration: 0.15),
            .removeFromParent()
        ]))
        detailBubble = nil
    }

    private func renderDetailBubble() {
        detailBubble?.removeFromParent()

        let bubble = SKNode()
        bubble.zPosition = 100

        var lines: [String] = []
        if currentSummaries.isEmpty {
            lines.append("Rate limits: No limits detected")
        } else {
            for s in currentSummaries {
                var parts: [String] = [s.agentDisplayName]
                if let f = s.rateLimits.fiveHour {
                    var text = "5h: \(f.usedPercent)%"
                    if let r = formatResetTime(f.resetsAt) { text += " (resets \(r))" }
                    parts.append(text)
                }
                if let w = s.rateLimits.sevenDay {
                    var text = "7d: \(w.usedPercent)%"
                    if let r = formatResetTime(w.resetsAt) { text += " (resets \(r))" }
                    parts.append(text)
                }
                lines.append(parts.joined(separator: "  |  "))
            }
        }

        let bubbleW: CGFloat = 220
        let bubbleH: CGFloat = CGFloat(lines.count) * 16 + 14
        let bubbleY: CGFloat = -Self.boardHeight / 2 - bubbleH / 2 - 8

        let shape = SKShapeNode(rect: CGRect(x: -bubbleW / 2, y: -bubbleH / 2, width: bubbleW, height: bubbleH),
                                cornerRadius: 4)
        shape.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.15, alpha: 0.96)
                : NSColor(white: 0.98, alpha: 0.96)
        }
        shape.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        shape.lineWidth = 1.0
        bubble.addChild(shape)

        for (i, lineText) in lines.enumerated() {
            let lbl = SKLabelNode(fontNamed: "SFMono-Regular")
            lbl.fontSize = 8.0
            lbl.fontColor = .labelColor
            lbl.text = lineText
            lbl.horizontalAlignmentMode = .center
            lbl.verticalAlignmentMode = .center
            let y = bubbleH / 2 - 12 - CGFloat(i) * 16
            lbl.position = CGPoint(x: 0, y: y)
            bubble.addChild(lbl)
        }

        bubble.position = CGPoint(x: 0, y: bubbleY)
        bubble.alpha = 0
        boardNode.addChild(bubble)
        bubble.run(.fadeIn(withDuration: 0.15))
        self.detailBubble = bubble
    }

    private func formatResetTime(_ epoch: Int?) -> String? {
        guard let epoch, epoch > 0 else { return nil }
        let now = Date().timeIntervalSince1970
        guard Double(epoch) - now > 0 else { return nil }
        let resetDate = Date(timeIntervalSince1970: Double(epoch))
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(resetDate) ? "HH:mm" : "M/d HH:mm"
        return formatter.string(from: resetDate)
    }
}
