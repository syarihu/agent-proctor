import AppKit
import Foundation
import Model
import SpriteKit

/// 異なる Organization 間の境界に設置されるオフィスローパーテーション（衝立）。
///
/// 腰高〜胸高の半透明すりガラスと吸音クロスパネルのコンビネーション構造を持ち、
/// 西側主通路（開口部）のポストには組織名を示すサインプレートが掲示される。
/// 立った状態でのオフィス全体の見通しを保ちつつ、異なるチーム・組織間のエリアを明確に分ける。
final class OfficePartitionNode: SKNode {
    // MARK: - カラー定義（Light / Dark 両対応）

    static let frameColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.32, green: 0.34, blue: 0.38, alpha: 0.95)
            : NSColor(red: 0.65, green: 0.68, blue: 0.74, alpha: 0.95)
    }

    static let topRailColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.38, green: 0.40, blue: 0.45, alpha: 0.98)
            : NSColor(red: 0.75, green: 0.78, blue: 0.83, alpha: 0.98)
    }

    static let glassFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.28, green: 0.40, blue: 0.52, alpha: 0.28)
            : NSColor(red: 0.74, green: 0.84, blue: 0.93, alpha: 0.38)
    }

    static let glassBorderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.45, green: 0.58, blue: 0.70, alpha: 0.35)
            : NSColor(red: 0.60, green: 0.72, blue: 0.84, alpha: 0.45)
    }

    static let fabricFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 0.92)
            : NSColor(red: 0.82, green: 0.84, blue: 0.88, alpha: 0.92)
    }

    static let kickplateColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.14, green: 0.15, blue: 0.17, alpha: 0.95)
            : NSColor(red: 0.52, green: 0.55, blue: 0.60, alpha: 0.95)
    }

    static let stabilizerColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.18, green: 0.19, blue: 0.22, alpha: 0.95)
            : NSColor(red: 0.58, green: 0.60, blue: 0.65, alpha: 0.95)
    }

    static let signBgColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.14, green: 0.16, blue: 0.20, alpha: 0.96)
            : NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 0.96)
    }

    static let signBorderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.50, blue: 0.70, alpha: 0.85)
            : NSColor(red: 0.30, green: 0.48, blue: 0.72, alpha: 0.85)
    }

    static let signTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.88, green: 0.92, blue: 0.98, alpha: 0.98)
            : NSColor(red: 0.15, green: 0.25, blue: 0.42, alpha: 0.98)
    }

    // MARK: - 組織アイコンテクスチャ

    static let orgIconTexture: SKTexture? = {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        let image = NSImage(systemSymbolName: "building.2.fill", accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "building.2", accessibilityDescription: nil)
        guard let symbol = image?.withSymbolConfiguration(config) else { return nil }
        let tinted = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor(red: 0.45, green: 0.65, blue: 0.90, alpha: 1.0).set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return SKTexture(image: tinted)
    }()

    // MARK: - 初期化

    init(orgName: String, startX: CGFloat, endX: CGFloat) {
        super.init()

        let totalWidth = max(40, endX - startX)
        name = "partition:\(orgName)"

        // 1. 床の接地影（パーテーションの存在感を床面に落とす）
        let shadow = SKShapeNode(rect: CGRect(x: startX - 2, y: -2, width: totalWidth + 4, height: 3),
                                 cornerRadius: 1.5)
        shadow.fillColor = .secondaryLabelColor.withAlphaComponent(0.08)
        shadow.strokeColor = .clear
        shadow.zPosition = -1
        addChild(shadow)

        // 2. モジュールパネルの分割計算
        // オフィス標準のモジュール幅（約60〜75pt）に合わせて等分割する
        let targetPanelWidth: CGFloat = 68.0
        let panelCount = max(1, Int(round(totalWidth / targetPanelWidth)))
        let panelWidth = totalWidth / CGFloat(panelCount)

        for j in 0..<panelCount {
            let pLeft = startX + CGFloat(j) * panelWidth
            let pWidth = panelWidth

            // a. 巾木（最下部キックプレート）
            let kickplate = SKShapeNode(rect: CGRect(x: pLeft + 0.5, y: 0, width: pWidth - 1, height: 3))
            kickplate.fillColor = Self.kickplateColor
            kickplate.strokeColor = .clear
            kickplate.zPosition = 0
            addChild(kickplate)

            // b. 下段吸音クロスパネル（布張り）
            let fabric = SKShapeNode(rect: CGRect(x: pLeft + 0.5, y: 3, width: pWidth - 1, height: 13))
            fabric.fillColor = Self.fabricFillColor
            fabric.strokeColor = .clear
            fabric.zPosition = 1
            addChild(fabric)

            // 細かな織り目（スリットライン）
            for sx in stride(from: pLeft + 14, to: pLeft + pWidth - 4, by: 16) {
                let path = CGMutablePath()
                path.move(to: CGPoint(x: sx, y: 4.5))
                path.addLine(to: CGPoint(x: sx, y: 14.5))
                let slit = SKShapeNode(path: path)
                slit.strokeColor = .secondaryLabelColor.withAlphaComponent(0.08)
                slit.lineWidth = 1.0
                slit.zPosition = 1.5
                addChild(slit)
            }

            // c. 中桟（アルミ境界レール）
            let midRail = SKShapeNode(rect: CGRect(x: pLeft + 0.5, y: 16, width: pWidth - 1, height: 1.5))
            midRail.fillColor = Self.frameColor
            midRail.strokeColor = .clear
            midRail.zPosition = 2
            addChild(midRail)

            // d. 上段半透明すりガラススクリーン
            let glass = SKShapeNode(rect: CGRect(x: pLeft + 0.5, y: 17.5, width: pWidth - 1, height: 15))
            glass.fillColor = Self.glassFillColor
            glass.strokeColor = Self.glassBorderColor
            glass.lineWidth = 0.8
            glass.zPosition = 1
            addChild(glass)

            // すりガラスのハイライト（光沢反射ライン）
            let glarePath = CGMutablePath()
            glarePath.move(to: CGPoint(x: pLeft + 4, y: 28.5))
            glarePath.addLine(to: CGPoint(x: pLeft + pWidth - 4, y: 28.5))
            let glare = SKShapeNode(path: glarePath)
            glare.strokeColor = NSColor.white.withAlphaComponent(0.22)
            glare.lineWidth = 1.0
            glare.zPosition = 1.5
            addChild(glare)

            // e. 笠木（最上部アルミフレーム天板）
            let topRail = SKShapeNode(rect: CGRect(x: pLeft, y: 32.5, width: pWidth, height: 3.5),
                                      cornerRadius: 0.5)
            topRail.fillColor = Self.topRailColor
            topRail.strokeColor = .clear
            topRail.zPosition = 2
            addChild(topRail)

            let topHighlightPath = CGMutablePath()
            topHighlightPath.move(to: CGPoint(x: pLeft, y: 36))
            topHighlightPath.addLine(to: CGPoint(x: pLeft + pWidth, y: 36))
            let topHighlight = SKShapeNode(path: topHighlightPath)
            topHighlight.strokeColor = NSColor.white.withAlphaComponent(0.35)
            topHighlight.lineWidth = 0.8
            topHighlight.zPosition = 2.5
            addChild(topHighlight)
        }

        // 3. 連結支柱および両端ポスト・安定脚
        for j in 0...panelCount {
            let postX = startX + CGFloat(j) * panelWidth
            let isEnd = (j == 0 || j == panelCount)
            let postW: CGFloat = isEnd ? 3.5 : 2.5

            // 垂直ポール
            let post = SKShapeNode(rect: CGRect(x: postX - postW / 2, y: 0, width: postW, height: 36),
                                   cornerRadius: 0.8)
            post.fillColor = Self.frameColor
            post.strokeColor = .clear
            post.zPosition = 2
            addChild(post)

            // 安定脚（T字型レッグ: 両端および2パネルおきに床面に配置）
            if isEnd || j % 2 == 0 {
                let foot = SKShapeNode(rect: CGRect(x: postX - 4.5, y: -3, width: 9, height: 4),
                                       cornerRadius: 1.2)
                foot.fillColor = Self.stabilizerColor
                foot.strokeColor = .clear
                foot.zPosition = 0.5
                addChild(foot)
            }
        }

        // 4. 西側通路沿いのエントランス支柱サインプレート
        let sign = buildSignNode(orgName: orgName, at: CGPoint(x: startX, y: 36))
        sign.zPosition = 5
        addChild(sign)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - サインプレート生成

    private func buildSignNode(orgName: String, at position: CGPoint) -> SKNode {
        let node = SKNode()
        node.position = position

        // 支柱からの立ち上がりブラケット
        let bracket = SKShapeNode(rect: CGRect(x: -1.5, y: 0, width: 3, height: 4))
        bracket.fillColor = Self.frameColor
        bracket.strokeColor = .clear
        node.addChild(bracket)

        // プレートの幅を文字長に応じて計算
        let displayText = SpeechBubbleNode.truncateScreenText(orgName, limit: 14)
        let textWidth = CGFloat(displayText.count) * 6.8
        let badgeWidth = max(56, min(140, textWidth + 30))
        let badgeHeight: CGFloat = 17

        let badgeRect = CGRect(x: -2, y: 4, width: badgeWidth, height: badgeHeight)
        let badge = SKShapeNode(rect: badgeRect, cornerRadius: 3.5)
        badge.fillColor = Self.signBgColor
        badge.strokeColor = Self.signBorderColor
        badge.lineWidth = 1.0
        node.addChild(badge)

        var leftX: CGFloat = 4

        // 組織ビルアイコン
        if let texture = Self.orgIconTexture {
            let icon = SKSpriteNode(texture: texture)
            icon.size = CGSize(width: 11, height: 11)
            icon.position = CGPoint(x: leftX + 5.5, y: 4 + badgeHeight / 2)
            node.addChild(icon)
            leftX += 14
        }

        // 組織名テキスト
        let label = SKLabelNode(fontNamed: "SFMono-Bold")
        label.fontSize = 9.0
        label.fontColor = Self.signTextColor
        label.horizontalAlignmentMode = .left
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: leftX, y: 4 + badgeHeight / 2 - 0.5)
        label.text = displayText
        node.addChild(label)

        return node
    }
}
