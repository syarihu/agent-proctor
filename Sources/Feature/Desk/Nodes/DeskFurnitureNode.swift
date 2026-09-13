import AppKit
import Foundation
import Model
import SpriteKit

/// 机1つ分の SpriteKit ノード。
///
/// セッション机またはリポジトリ見出し机 (hub) を表す。
/// 天板・前面・モニタ・思考雲吹き出し・作業ログが印字された帳票用紙・挙げた手マーク・書類の山・作業者および手伝いエージェントを包括する。
final class DeskFurnitureNode: SKNode {
    // MARK: - 寸法定数

    static let deskWidth: CGFloat = 184
    static let deskDepth: CGFloat = 24
    static let hubDeskWidth: CGFloat = 104
    static let maxSheetsPerSide = 6
    /// 連続帳票用紙の幅
    static let paperWidth: CGFloat = 226
    /// 紙の左右の余白（14pt ずつ）を除いた、文字に使える幅
    static let paperTextWidth: CGFloat = 226 - 28
    static let sheetWidth: CGFloat = 18
    static let sheetHeight: CGFloat = 5

    // MARK: - プロパティ

    let isHub: Bool
    let deskLabel: String
    let screen: SKShapeNode
    let occupant: PersonNode
    /// 席が空いているときだけ出す、机の後ろに収まった椅子
    let chair: SKNode
    let whiteboard: DeskWhiteboardNode
    var bubble: DeskWhiteboardNode { whiteboard }
    var paper: SKNode?
    var hand: SKNode?
    var nameplate: SKNode?
    let stackL: SKNode
    let stackR: SKNode

    // MARK: - ログ色定数

    static let logGreen = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.35, green: 0.98, blue: 0.50, alpha: 0.95)
            : NSColor(red: 0.12, green: 0.55, blue: 0.22, alpha: 1.0)
    }
    static let logCyan = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.40, green: 0.90, blue: 1.0, alpha: 0.95)
            : NSColor(red: 0.05, green: 0.45, blue: 0.75, alpha: 1.0)
    }
    static let logYellow = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.85, blue: 0.40, alpha: 0.95)
            : NSColor(red: 0.70, green: 0.45, blue: 0.05, alpha: 1.0)
    }
    static let logOrange = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.65, blue: 0.20, alpha: 0.95)
            : NSColor(red: 0.80, green: 0.35, blue: 0.05, alpha: 1.0)
    }
    static let logRed = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.45, blue: 0.45, alpha: 0.95)
            : NSColor(red: 0.78, green: 0.15, blue: 0.15, alpha: 1.0)
    }
    static let logDim = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.70, alpha: 0.85)
            : NSColor(white: 0.35, alpha: 0.9)
    }

    // MARK: - 卓上ネームプレート色定数

    static let nameplateStandColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.10, green: 0.09, blue: 0.07, alpha: 0.95)
            : NSColor(red: 0.38, green: 0.30, blue: 0.14, alpha: 0.95)
    }
    static let nameplateFillColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.14, green: 0.15, blue: 0.19, alpha: 0.98)
            : NSColor(red: 0.97, green: 0.96, blue: 0.92, alpha: 0.98)
    }
    static let nameplateBorderColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.76, green: 0.62, blue: 0.32, alpha: 0.85)
            : NSColor(red: 0.65, green: 0.50, blue: 0.20, alpha: 0.85)
    }
    static let nameplatePinColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.85, green: 0.72, blue: 0.40, alpha: 0.9)
            : NSColor(red: 0.55, green: 0.42, blue: 0.18, alpha: 0.9)
    }
    static let nameplateTextColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.95, green: 0.92, blue: 0.82, alpha: 0.98)
            : NSColor(red: 0.16, green: 0.14, blue: 0.12, alpha: 0.98)
    }

    // MARK: - 空席の椅子

    static let chairSeatColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.34, alpha: 0.95)
            : NSColor(white: 0.62, alpha: 0.95)
    }

    static let chairBackColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.44, alpha: 0.95)
            : NSColor(white: 0.50, alpha: 0.95)
    }

    /// 上から見た事務椅子。背もたれを北（奥）、座面を手前に置く
    static func createChairNode() -> SKNode {
        let node = SKNode()

        let seat = SKShapeNode(rect: CGRect(x: -9, y: -8, width: 18, height: 15), cornerRadius: 4)
        seat.fillColor = chairSeatColor
        seat.strokeColor = .clear
        node.addChild(seat)

        let back = SKShapeNode(rect: CGRect(x: -10, y: 5, width: 20, height: 5), cornerRadius: 2.5)
        back.fillColor = chairBackColor
        back.strokeColor = .clear
        back.zPosition = 1
        node.addChild(back)

        // 5本脚のキャスターベース。座面から覗く足先だけを描く
        for index in 0..<5 {
            let angle = CGFloat(index) * (.pi * 2 / 5) - .pi / 2
            let caster = SKShapeNode(circleOfRadius: 1.6)
            caster.position = CGPoint(x: cos(angle) * 11, y: sin(angle) * 9 - 1)
            caster.fillColor = chairBackColor
            caster.strokeColor = .clear
            caster.zPosition = -1
            node.addChild(caster)
        }

        return node
    }

    // MARK: - 挙げた手テクスチャ

    static let handTexture: SKTexture? = {
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

    static func createHandMark() -> SKNode {
        guard let handTexture else { return SKNode() }
        let node = SKSpriteNode(texture: handTexture)
        node.size = CGSize(width: 21, height: 25)
        node.anchorPoint = CGPoint(x: 0.5, y: 0.1)
        return node
    }

    // MARK: - 初期化

    init(at point: CGPoint, label: String, isHub: Bool, seat: DeskSeat?, orgName: String? = nil) {
        self.isHub = isHub
        self.deskLabel = label

        let width = isHub ? Self.hubDeskWidth : Self.deskWidth

        // 前面（暗い面で厚みを表現）
        let front = SKShapeNode(rect: CGRect(x: -width / 2, y: -Self.deskDepth / 2 - 9,
                                             width: width, height: 10),
                                cornerRadius: 2)
        front.fillColor = .secondaryLabelColor.withAlphaComponent(0.32)
        front.strokeColor = .clear

        // 天板
        let top = SKShapeNode(rect: CGRect(x: -width / 2, y: -Self.deskDepth / 2,
                                           width: width, height: Self.deskDepth),
                              cornerRadius: 2.5)
        top.fillColor = .secondaryLabelColor.withAlphaComponent(isHub ? 0.6 : 0.5)
        top.strokeColor = .clear

        // 机の上のモニタ
        let mWidth: CGFloat = isHub ? 52 : 108
        let mHeight: CGFloat = isHub ? 22 : 28
        let screenY: CGFloat = 9

        let stand = SKShapeNode(rect: CGRect(x: -mWidth / 6, y: screenY - 3, width: mWidth / 3, height: 5),
                                cornerRadius: 1.5)
        stand.fillColor = .secondaryLabelColor.withAlphaComponent(0.35)
        stand.strokeColor = .clear
        stand.zPosition = -1

        screen = SKShapeNode(rect: CGRect(x: -mWidth / 2, y: screenY,
                                          width: mWidth, height: mHeight),
                             cornerRadius: 2.5)
        screen.name = "screen"
        screen.fillColor = .secondaryLabelColor.withAlphaComponent(0.25)
        screen.strokeColor = .secondaryLabelColor.withAlphaComponent(0.4)
        screen.lineWidth = 1.0

        // 書類の山を載せる器
        stackL = SKNode()
        stackL.name = "stackL"
        stackL.position = CGPoint(x: -(width / 2 - 11), y: -6)
        stackL.zPosition = 3

        stackR = SKNode()
        stackR.name = "stackR"
        stackR.position = CGPoint(x: (width / 2 - 11), y: -6)
        stackR.zPosition = 3

        // 空席のときに見える椅子。人がいる間は人物の下に完全に隠れるので出さない
        chair = Self.createChairNode()
        chair.name = "chair"
        chair.position = CGPoint(x: 0, y: 30)
        chair.zPosition = -21
        chair.isHidden = true

        // 席の作業者（リポジトリ担当者は人間、セッション作業員はAIエージェント）
        occupant = PersonNode(kind: isHub ? .human : .agent)
        occupant.name = "occupant"
        occupant.setScale(1.2)
        occupant.position = CGPoint(x: 0, y: 30)
        occupant.zPosition = -20

        // 机背後の自立型ホワイトボード（タスク内容またはリポジトリ名を表示）
        // 作業員の頭部や身体に隠れず、机の右側から自然に見通せるよう少し右寄りに配置する
        whiteboard = DeskWhiteboardNode(isHub: isHub, initialText: label)
        whiteboard.position = CGPoint(x: isHub ? 12 : 18, y: 0)

        super.init()

        position = point
        zPosition = -point.y
        name = seat != nil ? "seat:\(seat!.id)" : "hub:\(label)"

        addChild(front)
        addChild(top)
        addChild(stand)
        addChild(screen)
        addChild(stackL)
        addChild(stackR)
        addChild(chair)
        addChild(occupant)
        addChild(whiteboard)

        // 卓上ネームプレート（セッション机はモデル名、ハブ机は所属Organizationを表示）
        let nameplateNode = Self.createNameplateNode()
        nameplateNode.position = CGPoint(x: 0, y: -2.5)
        nameplateNode.zPosition = 8
        nameplateNode.isHidden = true
        addChild(nameplateNode)
        self.nameplate = nameplateNode

        if isHub, let orgName, !orgName.isEmpty {
            updateNameplate(text: orgName)
        }

        if seat != nil {
            // 連続帳票用紙
            let paperNode = Self.createPrintedPaperNode(width: Self.paperWidth, height: 60)
            addChild(paperNode)
            self.paper = paperNode

            // 挙げた手
            let handNode = Self.createHandMark()
            handNode.name = "hand"
            handNode.position = CGPoint(x: mWidth / 2 + 13, y: screenY + 4)
            handNode.zPosition = 25
            handNode.isHidden = true
            addChild(handNode)
            self.hand = handNode
        }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - 見た目の反映 (Dress)

    /// 台帳の状態を机に反映する
    func dress(as seat: DeskSeat, isAway: Bool) {
        let move = DeskGesture.from(activity: seat.activity)
        let crew = seat.helpers.map { "\($0.id):\($0.activity ?? "-")" }.joined(separator: ",")
        let signature = """
            \(seat.status)/\(seat.needsPerson)/\(seat.subagents)/\(move)/\(crew)/\(isAway)/\(seat.activity ?? "-")/\(seat.isCurrent)/\(seat.tabNumber ?? -1)/\(seat.model ?? "-")/\(seat.agent ?? "-")/\(seat.branch ?? "-")
            """
        if userData == nil { userData = NSMutableDictionary() }
        let unchanged = userData?["dressed"] as? String == signature

        // 書類の山の更新
        let stacked = userData?["stacked"] as? Int
        if stacked != seat.contextPercent {
            userData?["stacked"] = seat.contextPercent ?? 0
            restack(percent: seat.contextPercent ?? 0)
        }
        if unchanged { return }
        userData?["dressed"] = signature

        let isMissing = seat.status == TaskStatus.missing
        whiteboard.isHidden = isMissing
        paper?.isHidden = isMissing

        // 卓上ネームプレートの表示更新
        if isMissing {
            nameplate?.isHidden = true
        } else {
            updateNameplate(text: seat.nameplateText)
        }

        // 席に人がいるかどうか
        let seated = !isMissing
            && seat.status != TaskStatus.waiting
            && !isAway
        occupant.isHidden = !seated
        if seated { occupant.setScale(1.2) }
        // 席を外している間は椅子が机に収まって見える
        chair.isHidden = seated || isMissing

        // 人の手が要るものだけ手を挙げる
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

        occupant.resetGesture()
        occupant.alpha = 1

        // 手伝いエージェントの更新
        let working = seat.status == TaskStatus.running || seat.status == TaskStatus.waiting
        setHelpers(helpers: working ? seat.helpers : [],
                   count: working ? seat.subagents : 0,
                   tint: .labelColor)
        occupant.position = CGPoint(x: 0, y: 30)
        occupant.zPosition = -20

        // 連続帳票用紙に作業ログを印刷
        let termLines = printedLogLines(seat: seat)
        for lineIndex in 0..<3 {
            let lineLabel = paper?.childNode(withName: "paperLine\(lineIndex)") as? SKLabelNode
            if lineIndex < termLines.count {
                // ログはファイルパスやコマンドがそのまま載るので、紙幅で切る。
                // 文字数で切ると日本語のタスク名やパスが紙からはみ出す
                if let lineLabel {
                    LabelFitting.fit(lineLabel, text: termLines[lineIndex].text,
                                     maxWidth: Self.paperTextWidth)
                }
                lineLabel?.fontColor = termLines[lineIndex].color
            } else {
                lineLabel?.text = nil
                lineLabel?.fontColor = .clear
            }
        }

        // 画面色と吹き出し枠線の更新
        let strokeColor: NSColor
        switch seat.status {
        case TaskStatus.running:
            screen.fillColor = NSColor(red: 0.06, green: 0.10, blue: 0.17, alpha: 0.95)
            screen.strokeColor = NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.85)
            strokeColor = NSColor(red: 0.310, green: 0.765, blue: 0.969, alpha: 0.9)
            occupant.applyGesture(move, isHelper: false)
        case TaskStatus.waiting:
            screen.fillColor = NSColor(red: 0.18, green: 0.11, blue: 0.04, alpha: 0.95)
            screen.strokeColor = NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.9)
            strokeColor = NSColor(red: 1.0, green: 0.655, blue: 0.149, alpha: 0.95)
        case TaskStatus.done:
            screen.fillColor = NSColor(red: 0.04, green: 0.14, blue: 0.07, alpha: 0.95)
            screen.strokeColor = NSColor(red: 0.400, green: 0.733, blue: 0.416, alpha: 0.85)
            strokeColor = NSColor(red: 0.400, green: 0.733, blue: 0.416, alpha: 0.85)
        case TaskStatus.failed:
            screen.fillColor = NSColor(red: 0.16, green: 0.04, blue: 0.04, alpha: 0.95)
            screen.strokeColor = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 0.85)
            strokeColor = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 0.85)
        case TaskStatus.seen:
            screen.fillColor = .secondaryLabelColor.withAlphaComponent(0.20)
            screen.strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
            strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
            occupant.alpha = 0.5
        default:
            screen.fillColor = .secondaryLabelColor.withAlphaComponent(0.20)
            screen.strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
            strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
        }

        whiteboard.update(text: seat.name, isCurrent: seat.isCurrent, tabNumber: seat.tabNumber,
                          branch: seat.branch, strokeColor: strokeColor)
        alpha = seat.status == TaskStatus.missing ? 0.45 : 1
    }

    // MARK: - サブエージェント (手伝い)

    func setHelpers(helpers: [DeskHelper], count: Int, tint: NSColor) {
        let shown = min(4, max(count, helpers.count))
        for index in 0..<4 {
            let name = "helper\(index)"
            guard index < shown else {
                childNode(withName: name)?.removeFromParent()
                continue
            }

            let helper: PersonNode
            let side: CGFloat = index % 2 == 0 ? -1 : 1
            let home = CGPoint(x: side * (Self.deskWidth / 2 + 16),
                               y: index < 2 ? 4 : 28)
            if let existing = childNode(withName: name) as? PersonNode {
                helper = existing
                helper.position = home
            } else {
                childNode(withName: name)?.removeFromParent()
                // 手伝いエージェント（サブエージェント）はAIとして生成
                helper = PersonNode(kind: .agent, tint: tint)
                helper.name = name
                helper.setScale(0.94)
                helper.position = home
                helper.zPosition = 10
                helper.alpha = 0.8
                addChild(helper)
            }

            let activity = index < helpers.count ? helpers[index].activity : nil
            let gesture = DeskGesture.from(activity: activity)
            helper.applyGesture(gesture, isHelper: true)
        }
    }

    // MARK: - 書類の山 (コンテキスト使用量)

    func restack(percent: Int) {
        let capped = min(100, max(0, percent))
        let total = Int((Double(capped) / 100 * Double(Self.maxSheetsPerSide * 2)).rounded())

        let tint: NSColor
        if capped >= 80 {
            tint = NSColor(red: 0.937, green: 0.325, blue: 0.314, alpha: 1)
        } else if capped >= 50 {
            tint = NSColor(red: 1.0, green: 0.718, blue: 0.302, alpha: 1)
        } else {
            tint = NSColor(white: 0.93, alpha: 1)
        }

        pile(stack: stackL, sheets: (total + 1) / 2, tint: tint)
        pile(stack: stackR, sheets: total / 2, tint: tint)
    }

    private func pile(stack: SKNode, sheets: Int, tint: NSColor) {
        stack.removeAllChildren()
        guard sheets > 0 else { return }

        for index in 0..<sheets {
            let sheet = SKShapeNode(
                rect: CGRect(x: -Self.sheetWidth / 2, y: 0, width: Self.sheetWidth, height: Self.sheetHeight),
                cornerRadius: 0.5)
            sheet.fillColor = tint.withAlphaComponent(0.9)
            sheet.strokeColor = .black.withAlphaComponent(0.14)
            sheet.lineWidth = 0.5
            sheet.position = CGPoint(x: CGFloat.random(in: -1.6...1.6),
                                     y: CGFloat(index) * Self.sheetHeight)
            stack.addChild(sheet)
        }
    }

    // MARK: - 作業ログ印字

    func printedLogLines(seat: DeskSeat) -> [(text: String, color: NSColor)] {
        let green = Self.logGreen
        let cyan = Self.logCyan
        let yellow = Self.logYellow
        let orange = Self.logOrange
        let red = Self.logRed
        let dim = Self.logDim

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
                        ("🔍 \(SpeechBubbleNode.truncateScreenText(file, limit: 28))", cyan),
                        ("import Foundation", dim),
                        ("reading...", dim),
                    ]
                case "Edit", "NotebookEdit", "replace_file_content", "write_to_file":
                    return [
                        ("✏️ \(SpeechBubbleNode.truncateScreenText(file, limit: 28))", green),
                        ("func update() {", dim),
                        ("saving changes █", green),
                    ]
                case "Bash", "run_command":
                    return [
                        ("$ \(SpeechBubbleNode.truncateScreenText(detail, limit: 26))", yellow),
                        ("executing...", dim),
                        ("exit status: 0 █", yellow),
                    ]
                case "Grep", "Glob", "grep_search", "find_by_name":
                    return [
                        ("🔎 \(SpeechBubbleNode.truncateScreenText(detail, limit: 28))", cyan),
                        ("pattern match: 42 lines", dim),
                        ("searching...", dim),
                    ]
                case "LS", "list_dir":
                    return [
                        ("📁 \(SpeechBubbleNode.truncateScreenText(detail, limit: 28))", cyan),
                        ("drwxr-xr-x 8 user staff", dim),
                        ("listing...", dim),
                    ]
                default:
                    return [
                        ("▶ \(SpeechBubbleNode.truncateScreenText(raw, limit: 28))", green),
                        ("processing...", dim),
                        ("status: running █", green),
                    ]
                }
            } else {
                return [
                    ("▶ agent working", green),
                    ("processing task...", dim),
                    ("status: running █", green),
                ]
            }

        case TaskStatus.waiting:
            let req = seat.helpers.first(where: { $0.activity != nil })?.activity
                ?? seat.activity
                ?? "approval"
            return [
                ("⚠️ WAITING APPROVAL", orange),
                ("> \(SpeechBubbleNode.truncateScreenText(req, limit: 28))", yellow),
                ("[ Confirm / Deny ] █", orange),
            ]

        case TaskStatus.done:
            return [
                ("✓ TASK COMPLETED", green),
                ("> \(SpeechBubbleNode.truncateScreenText(seat.name, limit: 28))", dim),
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
                ("✓ \(SpeechBubbleNode.truncateScreenText(seat.name, limit: 28))", dim),
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

    // MARK: - 帳票用紙ノード生成

    static func createPrintedPaperNode(width: CGFloat, height: CGFloat) -> SKNode {
        let paper = SKNode()
        paper.name = "printedPaper"

        let hw = width / 2
        let topY: CGFloat = -DeskFurnitureNode.deskDepth / 2 - 4
        let bottomY = topY - height

        let bg = SKShapeNode(rect: CGRect(x: -hw, y: bottomY, width: width, height: height),
                             cornerRadius: 2.5)
        bg.name = "paperBg"
        bg.fillColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0.08, green: 0.11, blue: 0.16, alpha: 0.96)
                : NSColor(red: 0.96, green: 0.96, blue: 0.93, alpha: 0.96)
        }
        bg.strokeColor = .secondaryLabelColor.withAlphaComponent(0.35)
        bg.lineWidth = 0.8
        paper.addChild(bg)

        // 両端のマージナルパンチ穴
        let holeRadius: CGFloat = 1.3
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

        // 帳票用紙の中央段ゼブラ帯
        let stripe = SKShapeNode(rect: CGRect(x: -hw + 9.5, y: topY - 37.5, width: width - 19.0, height: 19.0))
        stripe.fillColor = NSColor(red: 0.2, green: 0.6, blue: 0.35, alpha: 0.06)
        stripe.strokeColor = .clear
        paper.addChild(stripe)

        // 下端のミシン目
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
            let lineLabel = SKLabelNode(fontNamed: "Menlo-Bold")
            lineLabel.name = "paperLine\(lineIndex)"
            lineLabel.fontSize = 9.8
            lineLabel.horizontalAlignmentMode = .left
            lineLabel.verticalAlignmentMode = .center
            lineLabel.position = CGPoint(x: textLeft, y: topY - 9.0 - CGFloat(lineIndex) * 19.0)
            lineLabel.zPosition = 2
            lineLabel.fontColor = .clear
            paper.addChild(lineLabel)
        }

        paper.zPosition = 10
        return paper
    }

    // MARK: - 卓上ネームプレート

    static func createNameplateNode() -> SKNode {
        let node = SKNode()
        node.name = "nameplate"

        // 三角台座の底面・影
        let stand = SKShapeNode()
        stand.name = "nameplateStand"
        stand.fillColor = nameplateStandColor
        stand.strokeColor = .clear
        stand.zPosition = 1
        node.addChild(stand)

        // プレート板面（真鍮・アクリル調）
        let plate = SKShapeNode()
        plate.name = "nameplatePlate"
        plate.fillColor = nameplateFillColor
        plate.strokeColor = nameplateBorderColor
        plate.lineWidth = 0.8
        plate.zPosition = 2
        node.addChild(plate)

        // 左右の飾り留め金具（真鍮ピン）
        let pinL = SKShapeNode(circleOfRadius: 0.8)
        pinL.name = "nameplatePinL"
        pinL.fillColor = nameplatePinColor
        pinL.strokeColor = .clear
        pinL.zPosition = 3
        node.addChild(pinL)

        let pinR = SKShapeNode(circleOfRadius: 0.8)
        pinR.name = "nameplatePinR"
        pinR.fillColor = nameplatePinColor
        pinR.strokeColor = .clear
        pinR.zPosition = 3
        node.addChild(pinR)

        // モデル名ラベル
        let label = SKLabelNode(fontNamed: "Menlo-Bold")
        label.name = "nameplateLabel"
        label.fontSize = 7.5
        label.fontColor = nameplateTextColor
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.position = CGPoint(x: 0, y: -0.5)
        label.zPosition = 4
        node.addChild(label)

        return node
    }

    func updateNameplate(text: String?) {
        guard let nameplate else { return }
        guard let text, !text.isEmpty else {
            nameplate.isHidden = true
            return
        }
        nameplate.isHidden = false

        guard let label = nameplate.childNode(withName: "nameplateLabel") as? SKLabelNode,
              let plate = nameplate.childNode(withName: "nameplatePlate") as? SKShapeNode,
              let stand = nameplate.childNode(withName: "nameplateStand") as? SKShapeNode,
              let pinL = nameplate.childNode(withName: "nameplatePinL") as? SKShapeNode,
              let pinR = nameplate.childNode(withName: "nameplatePinR") as? SKShapeNode else { return }

        // プレートの最大幅に収まるまで文字を削る。
        // 先に文字数で切っていたが、プレート幅は測った文字幅から決めるので、
        // 収まらない文字数だとプレートだけが上限で止まって文字がはみ出す
        let maxW: CGFloat = isHub ? (Self.hubDeskWidth - 12) : 136
        LabelFitting.fit(label, text: text, maxWidth: maxW - 14)
        label.fontColor = Self.nameplateTextColor

        // 文字幅に応じてプレート幅を動的に設定（左右マージンと留め金具の余白を考慮）
        let measured = label.frame.width
        let plateW = min(maxW, max(46, measured + 14))
        let plateH: CGFloat = 11.5

        let plateRect = CGRect(x: -plateW / 2, y: -plateH / 2, width: plateW, height: plateH)
        plate.path = CGPath(roundedRect: plateRect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        plate.fillColor = Self.nameplateFillColor
        plate.strokeColor = Self.nameplateBorderColor

        let standRect = CGRect(x: -plateW / 2 - 1.5, y: -plateH / 2 - 1.5, width: plateW + 3.0, height: 2.5)
        stand.path = CGPath(roundedRect: standRect, cornerWidth: 1.0, cornerHeight: 1.0, transform: nil)
        stand.fillColor = Self.nameplateStandColor

        pinL.position = CGPoint(x: -plateW / 2 + 3.5, y: 0)
        pinL.fillColor = Self.nameplatePinColor
        pinR.position = CGPoint(x: plateW / 2 - 3.5, y: 0)
        pinR.fillColor = Self.nameplatePinColor
    }
}
