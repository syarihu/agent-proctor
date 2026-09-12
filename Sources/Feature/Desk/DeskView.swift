import Model
import SpriteKit
import SwiftUI

/// 作業場の俯瞰。一覧と同じ台帳を、机を並べた部屋として見せる。
///
/// 視点は 2D ゲームでよくある俯瞰 (見下ろしを少し斜めに倒したもの)。
/// 机に天板と前面の2枚を描くこと、手前のものほど後に描くこと、
/// 人が上下にも歩くこと、の3つで奥行きを出している。
/// 部屋はビューポートより広いことがあり、そのぶんはカメラで送る。
public struct DeskView: View {
    /// 間取りをどこまで出すか。
    ///
    /// サイドバーは幅 180pt まで細くできるので、西側のラウンジまで置くと
    /// ずっと画面外にあるものをパンして探すことになる。狭いほうは区画の境目だけにする
    public enum Style {
        /// サイドバー。壁もラウンジも出さない
        case compact
        /// オフィス窓。スイートの壁・共用ラウンジ・側面扉まで出す
        case suites

        var layoutStyle: OfficeLayoutStyle {
            switch self {
            case .compact: return .compact
            case .suites: return .suites
            }
        }
    }

    public let islands: [DeskIsland]
    public let rateLimits: [AgentQuotaSummary]
    /// サイドバーまたはオフィス窓が見えているか。隠れているあいだはコマ数を落とす
    public let running: Bool
    /// ズーム倍率等の状態永続化キー（オフィスウィンドウのみ保存し、サイドバーと分離する）
    public let persistenceKey: String?
    public let style: Style
    /// 机をクリックしたときに開くセッション。一覧の行クリックと同じ相手を渡す
    public var onOpen: (String) -> Void

    public init(islands: [DeskIsland],
                rateLimits: [AgentQuotaSummary] = [],
                running: Bool,
                persistenceKey: String? = nil,
                style: Style = .compact,
                onOpen: @escaping (String) -> Void) {
        self.islands = islands
        self.rateLimits = rateLimits
        self.running = running
        self.persistenceKey = persistenceKey
        self.style = style
        self.onOpen = onOpen
    }

    /// SwiftUI の再描画のたびにシーンが作り直されると、歩いている途中の人が
    /// 毎回入口に戻ってしまう。参照を1つ持ち続けるために箱に入れる
    @StateObject private var box = SceneBox()

    public var body: some View {
        // **止めるのではなくコマ数を落とす。**
        // `isPaused` で止めると、一度も描かないうちに止まった場合に
        // シーンが出ないまま view の地色 (白) が出る。アプリを立ち上げ直した直後は
        // サイドバーがまだ「見えている」と分かっていないので、必ずそこに落ちる。
        // 2fps なら常駐していても負荷はほぼ無く、描かれないことも無い
        DeskSKContainerView(scene: box.scene, running: running)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                box.scene.persistenceKey = persistenceKey
                box.scene.layoutStyle = style.layoutStyle
                box.scene.onOpen = onOpen
                box.scene.apply(islands: islands, rateLimits: rateLimits)
            }
            .onChange(of: islands) { islands in
                box.scene.apply(islands: islands, rateLimits: rateLimits)
            }
            .onChange(of: rateLimits) { rateLimits in
                box.scene.apply(islands: islands, rateLimits: rateLimits)
            }
            // 止まっている間は台帳の変化も大きさの変化も取りこぼす。
            // 動き出す時点でもう一度当て直さないと、止まる前の姿のまま再開する
            .onChange(of: running) { running in
                guard running else { return }
                box.scene.apply(islands: islands, rateLimits: rateLimits)
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
