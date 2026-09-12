import AppKit
import Foundation
import Model
import SpriteKit

/// ツール別（Claude Code、Antigravity 等）のオフィス壁掛けホワイトボードノード。
///
/// 以前の単一ボード詰め込みから、ツールごとに独立したホワイトボードとして壁面に並べる形式に変更した。
/// 文字サイズやゲージ幅を拡大し、クリックせずとも残り時間・リセット時刻が一目で把握できるようにしている。
final class WhiteboardNode: SKNode {
    // MARK: - 寸法定数

    static let boardWidth: CGFloat = 140
    static let boardHeight: CGFloat = 64

    // MARK: - プロパティ

    private(set) var summary: AgentQuotaSummary
    private let boardNode: SKNode
    private let contentNode: SKNode
    private var detailBubble: SKNode?
    private var isDetailOpen = false

    // MARK: - 初期化

    init(summary: AgentQuotaSummary) {
        self.summary = summary
        self.boardNode = SKNode()
        self.contentNode = SKNode()

        super.init()
        name = "whiteboard"
        // 作業員が北側通路を横切る際、ボードの前に人物が立つよう背面に配置する
        zPosition = -9970

        addChild(boardNode)
        boardNode.addChild(contentNode)

        buildFrameAndAccessories()
        renderContent()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 外枠と小物の構築

    private func buildFrameAndAccessories() {
        let w = Self.boardWidth
        let h = Self.boardHeight

        // 上部の壁掛け金具（2箇所）
        for dx in [-40.0, 40.0] {
            let bracket = SKShapeNode(rect: CGRect(x: dx - 3, y: h / 2 - 1, width: 6, height: 5),
                                      cornerRadius: 1)
            bracket.fillColor = NSColor(white: 0.35, alpha: 0.95)
            bracket.strokeColor = .clear
            bracket.zPosition = -1
            boardNode.addChild(bracket)
        }

        // ホワイトボード本体（アルミ枠＋光沢白板）
        let board = SKShapeNode(rect: CGRect(x: -w / 2, y: -h / 2, width: w, height: h),
                                cornerRadius: 3.5)
        board.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.93, alpha: 0.98)
                : NSColor(calibratedWhite: 0.98, alpha: 0.99)
        }
        board.strokeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.58, alpha: 1.0)
                : NSColor(white: 0.72, alpha: 1.0)
        }
        board.lineWidth = 1.8
        board.zPosition = 0
        boardNode.addChild(board)

        // ペン置きトレイ（下部のアルミ棚）
        let tray = SKShapeNode(rect: CGRect(x: -w / 2 + 12, y: -h / 2 - 3, width: w - 24, height: 3.0),
                               cornerRadius: 0.8)
        tray.fillColor = NSColor(white: 0.65, alpha: 1.0)
        tray.strokeColor = NSColor(white: 0.45, alpha: 0.8)
        tray.lineWidth = 0.6
        tray.zPosition = 2
        boardNode.addChild(tray)

        // 黒板消し（イレーザー）
        let eraser = SKShapeNode(rect: CGRect(x: -w / 2 + 16, y: -h / 2 - 2, width: 12, height: 4.5),
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
            let pen = SKShapeNode(rect: CGRect(x: -w / 2 + 34 + CGFloat(i) * 9, y: -h / 2 - 1.5, width: 6, height: 2.2),
                                  cornerRadius: 0.5)
            pen.fillColor = color
            pen.strokeColor = .clear
            pen.zPosition = 3
            boardNode.addChild(pen)
        }

        // 右上の丸いマグネット（ツールごとのテーマカラーに合わせる）
        let magnet = SKShapeNode(circleOfRadius: 2.6)
        magnet.fillColor = markerColor(for: summary.agent)
        magnet.strokeColor = NSColor(white: 0.4, alpha: 0.5)
        magnet.lineWidth = 0.5
        magnet.position = CGPoint(x: w / 2 - 9, y: h / 2 - 9)
        magnet.zPosition = 4
        boardNode.addChild(magnet)
    }

    // MARK: - 板書コンテンツの描画

    func update(summary: AgentQuotaSummary) {
        guard self.summary != summary else { return }
        self.summary = summary
        renderContent()
        if isDetailOpen {
            renderDetailBubble()
        }
    }

    private func renderContent() {
        contentNode.removeAllChildren()
        contentNode.zPosition = 5

        let w = Self.boardWidth
        let h = Self.boardHeight

        // 見出しタイトル（ツール表示名）
        let titleLabel = SKLabelNode(fontNamed: "SFMono-Bold")
        titleLabel.fontSize = 8.2
        titleLabel.fontColor = markerColor(for: summary.agent)
        titleLabel.text = formattedTitle()
        titleLabel.horizontalAlignmentMode = .center
        titleLabel.verticalAlignmentMode = .center
        titleLabel.position = CGPoint(x: 0, y: h / 2 - 11)
        contentNode.addChild(titleLabel)

        // 見出し下のアンダーライン（手書き風アクセント）
        let line = SKShapeNode(rect: CGRect(x: -w / 2 + 12, y: h / 2 - 17, width: w - 24, height: 0.8))
        line.fillColor = markerColor(for: summary.agent).withAlphaComponent(0.4)
        line.strokeColor = .clear
        contentNode.addChild(line)

        // 5時間枠と7日間枠の表示
        let fiveRow = createGaugeRow(label: "5h", window: summary.rateLimits.fiveHour)
        fiveRow.position = CGPoint(x: 0, y: 6)
        contentNode.addChild(fiveRow)

        let weekRow = createGaugeRow(label: "7d", window: summary.rateLimits.sevenDay)
        weekRow.position = CGPoint(x: 0, y: -15)
        contentNode.addChild(weekRow)
    }

    private func createGaugeRow(label: String, window: RateLimitWindow?) -> SKNode {
        let node = SKNode()
        let w = Self.boardWidth

        // 枠ラベル ("5h" / "7d")
        let lbl = SKLabelNode(fontNamed: "SFMono-Bold")
        lbl.fontSize = 7.5
        lbl.fontColor = NSColor(white: 0.35, alpha: 0.95)
        lbl.text = label
        lbl.horizontalAlignmentMode = .left
        lbl.verticalAlignmentMode = .center
        lbl.position = CGPoint(x: -w / 2 + 10, y: 0)
        node.addChild(lbl)

        let gaugeX = -w / 2 + 30
        let gaugeWidth: CGFloat = 46
        let gaugeHeight: CGFloat = 6

        // ゲージ背景
        let bg = SKShapeNode(rect: CGRect(x: gaugeX, y: -gaugeHeight / 2, width: gaugeWidth, height: gaugeHeight),
                             cornerRadius: 1.5)
        bg.fillColor = NSColor(white: 0.86, alpha: 0.95)
        bg.strokeColor = .clear
        node.addChild(bg)

        if let window {
            let clamped = max(0, min(100, window.usedPercent))
            let fillWidth = gaugeWidth * CGFloat(clamped) / 100.0
            if fillWidth > 0.5 {
                let fill = SKShapeNode(rect: CGRect(x: gaugeX, y: -gaugeHeight / 2, width: fillWidth, height: gaugeHeight),
                                       cornerRadius: 1.5)
                fill.fillColor = gaugeColor(percent: clamped)
                fill.strokeColor = .clear
                node.addChild(fill)
            }

            // パーセント数値
            let pctLabel = SKLabelNode(fontNamed: "SFMono-Bold")
            pctLabel.fontSize = 7.2
            pctLabel.fontColor = gaugeColor(percent: clamped)
            pctLabel.text = "\(clamped)%"
            pctLabel.horizontalAlignmentMode = .left
            pctLabel.verticalAlignmentMode = .center
            pctLabel.position = CGPoint(x: gaugeX + gaugeWidth + 5, y: 0)
            node.addChild(pctLabel)

            // リセット時刻（板書上で確認できるよう配置）
            if let r = formatResetTime(window.resetsAt) {
                let resetLabel = SKLabelNode(fontNamed: "SFMono-Regular")
                resetLabel.fontSize = 6.0
                resetLabel.fontColor = NSColor(white: 0.42, alpha: 0.95)
                resetLabel.text = r
                resetLabel.horizontalAlignmentMode = .right
                resetLabel.verticalAlignmentMode = .center
                resetLabel.position = CGPoint(x: w / 2 - 10, y: 0)
                node.addChild(resetLabel)
            }
        } else {
            // 未計測またはリミットなし
            let pctLabel = SKLabelNode(fontNamed: "SFMono-Regular")
            pctLabel.fontSize = 6.8
            pctLabel.fontColor = NSColor(white: 0.55, alpha: 0.9)
            pctLabel.text = "--%"
            pctLabel.horizontalAlignmentMode = .left
            pctLabel.verticalAlignmentMode = .center
            pctLabel.position = CGPoint(x: gaugeX + gaugeWidth + 5, y: 0)
            node.addChild(pctLabel)

            let noLimitLabel = SKLabelNode(fontNamed: "SFMono-Regular")
            noLimitLabel.fontSize = 6.0
            noLimitLabel.fontColor = NSColor(white: 0.60, alpha: 0.9)
            noLimitLabel.text = "--"
            noLimitLabel.horizontalAlignmentMode = .right
            noLimitLabel.verticalAlignmentMode = .center
            noLimitLabel.position = CGPoint(x: w / 2 - 10, y: 0)
            node.addChild(noLimitLabel)
        }

        return node
    }

    private func formattedTitle() -> String {
        let base: String
        switch summary.agent {
        case "claude": base = "CLAUDE CODE"
        case "agy": base = "ANTIGRAVITY"
        case "codex": base = "CODEX"
        default: base = summary.agentDisplayName.uppercased()
        }

        if let acc = summary.account, !acc.isEmpty {
            return "\(base) (\(acc.uppercased()))"
        }
        return base
    }

    private func markerColor(for agent: String) -> NSColor {
        switch agent {
        case "claude":
            return NSColor(red: 0.85, green: 0.42, blue: 0.15, alpha: 0.98) // テラコッタ／アンバー
        case "agy":
            return NSColor(red: 0.22, green: 0.46, blue: 0.90, alpha: 0.98) // インディゴブルー
        case "codex":
            return NSColor(red: 0.15, green: 0.65, blue: 0.36, alpha: 0.98) // フォレストグリーン
        default:
            return NSColor(white: 0.25, alpha: 0.98)
        }
    }

    private func gaugeColor(percent: Int) -> NSColor {
        if percent >= 90 {
            return NSColor(red: 0.88, green: 0.20, blue: 0.18, alpha: 0.98)
        } else if percent >= 70 {
            return NSColor(red: 0.92, green: 0.54, blue: 0.10, alpha: 0.98)
        } else {
            return NSColor(red: 0.16, green: 0.70, blue: 0.28, alpha: 0.98)
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

    override func removeFromParent() {
        detailBubble?.removeFromParent()
        detailBubble = nil
        super.removeFromParent()
    }

    private func renderDetailBubble() {
        detailBubble?.removeFromParent()

        // ホワイトボード自体は壁レイヤー（zPosition: -9970）に配置されているため、
        // 吹き出しを WhiteboardNode の子にしてしまうと作業員や思考雲（zPosition: 5000）の
        // 背面に隠れてしまう。そのため親コンテナ（room）に最前面レイヤー（zPosition: 15000）として配置する
        guard let container = parent else { return }

        let bubble = SKNode()
        bubble.name = "whiteboardDetail"
        // 部屋全体の思考雲（実効 zPosition: 約4700）や作業員より確実に前面へ出す
        bubble.zPosition = 15000

        var lines: [String] = []

        if let f = summary.rateLimits.fiveHour {
            var text = "5-Hour: \(f.usedPercent)%"
            if let r = formatResetTime(f.resetsAt) {
                text += " (resets \(r)"
                if let rem = formatRemainingTime(f.resetsAt) { text += ", in \(rem)" }
                text += ")"
            }
            lines.append(text)
        } else {
            lines.append("5-Hour: No limits reported")
        }

        if let w = summary.rateLimits.sevenDay {
            var text = "7-Day: \(w.usedPercent)%"
            if let r = formatResetTime(w.resetsAt) {
                text += " (resets \(r)"
                if let rem = formatRemainingTime(w.resetsAt) { text += ", in \(rem)" }
                text += ")"
            }
            lines.append(text)
        } else {
            lines.append("7-Day: No limits reported")
        }

        let header = summary.agentDisplayName
        lines.insert(header, at: 0)

        let bubbleW: CGFloat = 240
        let bubbleH: CGFloat = CGFloat(lines.count) * 17 + 16
        let bubbleY: CGFloat = -Self.boardHeight / 2 - bubbleH / 2 - 10

        // ポップオーバー背面のドロップシャドウ
        let shadow = SKShapeNode(rect: CGRect(x: -bubbleW / 2 + 1, y: -bubbleH / 2 - 3, width: bubbleW, height: bubbleH),
                                 cornerRadius: 5.5)
        shadow.fillColor = NSColor.black.withAlphaComponent(0.28)
        shadow.strokeColor = .clear
        shadow.zPosition = -1
        bubble.addChild(shadow)

        // ポップオーバー本体
        let shape = SKShapeNode(rect: CGRect(x: -bubbleW / 2, y: -bubbleH / 2, width: bubbleW, height: bubbleH),
                                cornerRadius: 5.0)
        shape.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(calibratedWhite: 0.12, alpha: 0.98)
                : NSColor(calibratedWhite: 0.99, alpha: 0.98)
        }
        shape.strokeColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.45, alpha: 0.90)
                : NSColor(white: 0.70, alpha: 0.90)
        }
        shape.lineWidth = 1.2
        bubble.addChild(shape)

        // ホワイトボード下部へ向けた三角ポインター
        let pointerPath = CGMutablePath()
        pointerPath.move(to: CGPoint(x: -6, y: bubbleH / 2))
        pointerPath.addLine(to: CGPoint(x: 0, y: bubbleH / 2 + 7))
        pointerPath.addLine(to: CGPoint(x: 6, y: bubbleH / 2))
        pointerPath.closeSubpath()
        let pointer = SKShapeNode(path: pointerPath)
        pointer.fillColor = shape.fillColor
        pointer.strokeColor = shape.strokeColor
        pointer.lineWidth = shape.lineWidth
        bubble.addChild(pointer)

        // タイトル下の区切り線
        let divider = SKShapeNode(rect: CGRect(x: -bubbleW / 2 + 14, y: bubbleH / 2 - 24, width: bubbleW - 28, height: 0.8))
        divider.fillColor = markerColor(for: summary.agent).withAlphaComponent(0.3)
        divider.strokeColor = .clear
        bubble.addChild(divider)

        for (i, lineText) in lines.enumerated() {
            let lbl = SKLabelNode(fontNamed: i == 0 ? "SFMono-Bold" : "SFMono-Regular")
            lbl.fontSize = i == 0 ? 8.5 : 7.6
            lbl.fontColor = i == 0 ? markerColor(for: summary.agent) : .labelColor
            lbl.text = lineText
            lbl.horizontalAlignmentMode = .center
            lbl.verticalAlignmentMode = .center
            let y = bubbleH / 2 - 13 - CGFloat(i) * 17
            lbl.position = CGPoint(x: 0, y: y)
            bubble.addChild(lbl)
        }

        // 親コンテナ（room）の座標系に合わせて配置
        bubble.position = CGPoint(x: position.x, y: position.y + bubbleY)
        bubble.alpha = 0
        container.addChild(bubble)
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

    private func formatRemainingTime(_ epoch: Int?) -> String? {
        guard let epoch, epoch > 0 else { return nil }
        let now = Date().timeIntervalSince1970
        let diff = Double(epoch) - now
        guard diff > 0 else { return nil }
        let hours = Int(diff) / 3600
        let minutes = (Int(diff) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}
