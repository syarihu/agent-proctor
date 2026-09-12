import AppKit
import Foundation
import SpriteKit

/// 机の後ろに自立するモバイルホワイトボード（タスク内容またはリポジトリ名を表示する）ノード。
///
/// 従来の頭上思考雲吹き出しから、オフィス空間に馴染むキャスター付き自立型ホワイトボードに変更した。
/// アルミフレーム、T字脚、キャスター車輪、ペントレー、イレーザー、マーカーペン、マグネット式タブ番号バッジを備える。
final class DeskWhiteboardNode: SKNode {
    let isHub: Bool
    let boardWidth: CGFloat
    let boardHeight: CGFloat
    let boardCenterY: CGFloat

    // 板面と装飾
    let board: SKShapeNode
    let label1: SKLabelNode
    let label2: SKLabelNode
    var label: SKLabelNode { label1 }
    let statusBar: SKShapeNode
    let statusMagnet: SKShapeNode

    // タブ番号マグネットバッジ（⌘1など）
    var tabBadge: SKNode?
    var tabBadgeBg: SKShapeNode?
    var tabBadgeLabel: SKLabelNode?

    init(isHub: Bool, initialText: String) {
        self.isHub = isHub

        // 机幅（通常席184pt、hub104pt）や列間ピッチ（242pt）に干渉せず、
        // かつタスク名が2行に渡ってもゆったり収まるよう、板面の高さを従来の1.5倍（約54pt）に拡大
        let width: CGFloat = isHub ? 180 : 196
        let height: CGFloat = isHub ? 56 : 54
        let boardBottomY: CGFloat = 58
        let centerY: CGFloat = boardBottomY + height / 2
        self.boardWidth = isHub ? 158 : 174
        self.boardHeight = height
        self.boardCenterY = centerY

        // 板面本体（アルミ外枠＋光沢ホーロー白板）
        let bw = self.boardWidth
        let bh = height
        let boardRect = CGRect(x: -bw / 2, y: centerY - bh / 2, width: bw, height: bh)
        board = SKShapeNode(rect: boardRect, cornerRadius: 2.5)
        board.name = "whiteboardBody"
        board.fillColor = Self.boardSurfaceColor
        board.strokeColor = Self.metalStrokeColor
        board.lineWidth = 1.4
        board.zPosition = 4

        // 上部ステータスカラー帯（タスクの状態を示すマグネットテープ風アクセント）
        let statusRect = CGRect(x: -bw / 2 + 1.5, y: centerY + bh / 2 - 3.2, width: bw - 3.0, height: 2.4)
        statusBar = SKShapeNode(rect: statusRect, cornerRadius: 0.8)
        statusBar.name = "statusBar"
        statusBar.fillColor = isHub ? NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.85) : .clear
        statusBar.strokeColor = .clear
        statusBar.zPosition = 5

        // 右上の丸型ステータスマグネット
        statusMagnet = SKShapeNode(circleOfRadius: 2.6)
        statusMagnet.name = "statusMagnet"
        statusMagnet.position = CGPoint(x: bw / 2 - 8, y: centerY + bh / 2 - 7)
        statusMagnet.fillColor = isHub ? NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.95) : NSColor(white: 0.6, alpha: 0.6)
        statusMagnet.strokeColor = NSColor(white: 0.35, alpha: 0.4)
        statusMagnet.lineWidth = 0.5
        statusMagnet.zPosition = 6

        // 板書テキスト（1行目・2行目）
        label1 = SKLabelNode(fontNamed: "SFMono-Bold")
        label1.name = "whiteboardLabel1"
        label1.fontColor = Self.markerInkColor(isHub: isHub)
        label1.horizontalAlignmentMode = .center
        label1.verticalAlignmentMode = .center
        label1.zPosition = 6

        label2 = SKLabelNode(fontNamed: "SFMono-Bold")
        label2.name = "whiteboardLabel2"
        label2.fontColor = Self.markerInkColor(isHub: isHub)
        label2.horizontalAlignmentMode = .center
        label2.verticalAlignmentMode = .center
        label2.zPosition = 6

        super.init()
        name = "deskWhiteboard"
        // 作業員の背後（椅子・人物の後ろ側）に自立させるため、座席作業員 (-20) より背面に配置する
        zPosition = -22

        // MARK: 1. 自立スタンド（T字脚・キャスター車輪・床の影）
        let legX = width / 2 - 10
        let floorY: CGFloat = 25

        for side: CGFloat in [-1, 1] {
            let x = side * legX

            // 床の接地影
            let shadow = SKShapeNode(ellipseOf: CGSize(width: 20, height: 4.5))
            shadow.position = CGPoint(x: x, y: floorY - 3.5)
            shadow.fillColor = .black.withAlphaComponent(0.12)
            shadow.strokeColor = .clear
            shadow.zPosition = 1
            addChild(shadow)

            // キャスター車輪（前後の2輪）
            for wheelDx: CGFloat in [-5.5, 5.5] {
                let wheel = SKShapeNode(circleOfRadius: 1.5)
                wheel.position = CGPoint(x: x + wheelDx, y: floorY - 1.5)
                wheel.fillColor = NSColor(white: 0.22, alpha: 0.95)
                wheel.strokeColor = .clear
                wheel.zPosition = 2
                addChild(wheel)
            }

            // T字脚バー（水平ベース）
            let footBar = SKShapeNode(rect: CGRect(x: x - 9, y: floorY, width: 18, height: 3.2),
                                      cornerRadius: 1.0)
            footBar.fillColor = Self.metalFrameColor
            footBar.strokeColor = Self.metalStrokeColor
            footBar.lineWidth = 0.6
            footBar.zPosition = 3
            addChild(footBar)

            // 垂直支柱（キャスターベースからボード上端まで伸びるアルミ角パイプ）
            let postH = (centerY + height / 2 + 3) - floorY
            let post = SKShapeNode(rect: CGRect(x: x - 1.6, y: floorY, width: 3.2, height: postH),
                                   cornerRadius: 0.8)
            post.fillColor = Self.metalFrameColor
            post.strokeColor = Self.metalStrokeColor
            post.lineWidth = 0.6
            post.zPosition = 3
            addChild(post)

            // ボード側面の回転・固定ネジノブ
            let knob = SKShapeNode(circleOfRadius: 2.2)
            knob.position = CGPoint(x: x + side * 1.5, y: centerY)
            knob.fillColor = NSColor(white: 0.25, alpha: 0.95)
            knob.strokeColor = Self.metalStrokeColor
            knob.lineWidth = 0.5
            knob.zPosition = 8
            addChild(knob)

            let knobPin = SKShapeNode(circleOfRadius: 0.8)
            knobPin.position = knob.position
            knobPin.fillColor = Self.metalFrameColor
            knobPin.strokeColor = .clear
            knobPin.zPosition = 9
            addChild(knobPin)
        }

        // 下部補強クロスバーは作業員（エージェント）の身体と重なって視認性を損ねるため設けない

        // MARK: 2. ホワイトボード本体とステータス表示
        addChild(board)
        addChild(statusBar)
        addChild(statusMagnet)

        // MARK: 3. ペントレー・イレーザー・マーカーペン
        let trayW = bw - 16
        let trayY = centerY - bh / 2 - 1.5
        let tray = SKShapeNode(rect: CGRect(x: -trayW / 2, y: trayY, width: trayW, height: 2.6),
                               cornerRadius: 0.6)
        tray.fillColor = Self.metalFrameColor
        tray.strokeColor = Self.metalStrokeColor
        tray.lineWidth = 0.5
        tray.zPosition = 5
        addChild(tray)

        // イレーザー（黒板消し）
        let eraser = SKShapeNode(rect: CGRect(x: -trayW / 2 + 8, y: trayY + 0.8, width: 10, height: 3.6),
                                 cornerRadius: 0.6)
        eraser.fillColor = NSColor(white: 0.24, alpha: 0.95)
        eraser.strokeColor = .clear
        eraser.zPosition = 6
        addChild(eraser)

        // マーカーペン（黒・赤・青）
        let pens: [(CGFloat, NSColor)] = [
            (22, NSColor(white: 0.15, alpha: 0.95)),
            (30, NSColor(red: 0.85, green: 0.20, blue: 0.20, alpha: 0.95)),
            (38, NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.95))
        ]
        for (dx, color) in pens {
            let pen = SKShapeNode(rect: CGRect(x: -trayW / 2 + dx, y: trayY + 1.0, width: 5.5, height: 1.8),
                                  cornerRadius: 0.4)
            pen.fillColor = color
            pen.strokeColor = .clear
            pen.zPosition = 6
            addChild(pen)
        }

        // MARK: 4. 板書テキスト
        addChild(label1)
        addChild(label2)
        applyText(initialText)

        // MARK: 5. マグネット式タブ番号バッジ（⌘1など）
        if !isHub {
            let badge = SKNode()
            badge.name = "tabBadge"
            badge.position = CGPoint(x: -bw / 2 + 17, y: centerY + bh / 2 - 2)
            badge.zPosition = 10
            badge.isHidden = true

            let colors = Self.tabBadgeColors(isCurrent: false)
            let badgeBg = SKShapeNode(rect: CGRect(x: -12, y: -6.5, width: 24, height: 13),
                                      cornerRadius: 2.5)
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
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 状態更新

    /// テキストを1行または2行に整形して配置する
    private func applyText(_ text: String) {
        let lines = Self.formatWhiteboardLines(text, limitPerLine: isHub ? 20 : 23)
        if lines.count == 1 {
            label1.text = lines[0]
            label1.position = CGPoint(x: 0, y: boardCenterY)
            label1.fontSize = isHub ? 12.5 : 11.2
            label2.text = nil
            label2.isHidden = true
        } else {
            label1.text = lines[0]
            label1.position = CGPoint(x: 0, y: boardCenterY + 7.5)
            label1.fontSize = isHub ? 11.0 : 10.2
            label2.text = lines[1]
            label2.position = CGPoint(x: 0, y: boardCenterY - 7.5)
            label2.fontSize = isHub ? 11.0 : 10.2
            label2.isHidden = false
        }
        label1.fontColor = Self.markerInkColor(isHub: isHub)
        label2.fontColor = Self.markerInkColor(isHub: isHub)
    }

    /// テキスト・枠線色・アクティブ状態・タブ番号を更新する
    func update(text: String, isCurrent: Bool, tabNumber: Int?, strokeColor: NSColor) {
        applyText(text)

        // ステータスカラー帯とマグネットの更新（タスク状態を視覚的に通知）
        if isHub {
            statusBar.fillColor = NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.85)
            statusMagnet.fillColor = NSColor(red: 0.20, green: 0.45, blue: 0.85, alpha: 0.95)
        } else {
            statusBar.fillColor = strokeColor
            statusMagnet.fillColor = strokeColor
        }

        // アクティブ表示（iTerm2 で現在閲覧中）の場合は外枠を強調ハイライト
        if isCurrent {
            board.strokeColor = NSColor(red: 0.25, green: 0.65, blue: 0.98, alpha: 0.95)
            board.lineWidth = 2.2
        } else {
            board.strokeColor = Self.metalStrokeColor
            board.lineWidth = 1.4
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

    // MARK: - カラー定数

    static let metalFrameColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.60, alpha: 0.95)
            : NSColor(white: 0.72, alpha: 0.95)
    }

    static let metalStrokeColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.42, alpha: 0.95)
            : NSColor(white: 0.55, alpha: 0.95)
    }

    static let boardSurfaceColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(calibratedWhite: 0.94, alpha: 0.98)
            : NSColor(calibratedWhite: 0.98, alpha: 0.99)
    }

    static func markerInkColor(isHub: Bool) -> NSColor {
        if isHub {
            return NSColor(red: 0.08, green: 0.18, blue: 0.36, alpha: 0.96)
        }
        return NSColor(red: 0.12, green: 0.14, blue: 0.18, alpha: 0.96)
    }

    /// タブ番号マグネットバッジの色
    static func tabBadgeColors(isCurrent: Bool) -> (bg: NSColor, stroke: NSColor, text: NSColor, width: CGFloat) {
        if isCurrent {
            return (
                bg: NSColor(red: 0.10, green: 0.45, blue: 0.85, alpha: 0.98),
                stroke: NSColor(red: 0.40, green: 0.75, blue: 1.0, alpha: 0.90),
                text: .white,
                width: 1.0
            )
        } else {
            return (
                bg: NSColor(white: 0.28, alpha: 0.95),
                stroke: NSColor(white: 0.45, alpha: 0.80),
                text: NSColor(white: 0.95, alpha: 0.98),
                width: 0.8
            )
        }
    }

    /// 1行に収まらない場合に自然な区切りで2行に分割する
    static func formatWhiteboardLines(_ text: String, limitPerLine: Int = 23) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= limitPerLine {
            return [trimmed]
        }

        // 2行に分割する最適な分割点を探す
        let targetSplit = min(limitPerLine, max(8, trimmed.count / 2 + 2))
        let chars = Array(trimmed)

        // 1. 空白文字での分割を優先探索
        var bestIndex: Int?
        var minDistance = Int.max
        for i in 6...min(limitPerLine, chars.count - 4) {
            if chars[i] == " " || chars[i] == "\t" {
                let dist = abs(i - targetSplit)
                if dist < minDistance {
                    minDistance = dist
                    bestIndex = i
                }
            }
        }

        // 2. 空白がなければ区切り記号（/、-、_、:、・、など）を探す
        if bestIndex == nil {
            let delimiters: Set<Character> = ["/", "-", "_", ":", "：", "・", "、", "。", " ", "　"]
            for i in 6...min(limitPerLine, chars.count - 3) {
                if delimiters.contains(chars[i]) {
                    let dist = abs(i - targetSplit)
                    if dist < minDistance {
                        minDistance = dist
                        // 区切り記号を行末に残すため i + 1 で分割
                        bestIndex = i + 1
                    }
                }
            }
        }

        // 3. 区切りがなければ limitPerLine または targetSplit で分割
        let splitAt = bestIndex ?? min(limitPerLine, targetSplit)

        let line1 = String(chars[0..<splitAt]).trimmingCharacters(in: .whitespaces)
        var line2 = String(chars[splitAt..<chars.count]).trimmingCharacters(in: .whitespaces)

        // 2行目が長すぎる場合は末尾を省略
        if line2.count > limitPerLine {
            line2 = String(line2.prefix(limitPerLine - 1)) + "…"
        }

        return [line1, line2]
    }

    /// 画面幅に収まるよう文字数を切り詰める（単一行切り詰め用互換関数）
    static func truncateScreenText(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit - 1)) + "…"
    }
}

/// 互換性エイリアス
typealias SpeechBubbleNode = DeskWhiteboardNode
