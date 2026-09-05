import AppKit
import CoreGraphics
import ItermBridge

/// サイドバーの居場所を作る。
///
/// サイドバーは iTerm2 のウィンドウの左隣に並ぶが、ウィンドウが画面いっぱいに
/// 広がっていると左に隙間が無く、画面の端で止まって端末に重なってしまう。
/// そこで iTerm2 のウィンドウの**左端だけ**を右へ寄せる。右端は動かさないので、
/// 見た目には「サイドバーの分だけ端末が細くなる」形になる。
///
/// 相手にするのは2種類の窓だけ。
///   - 画面の左端に張り付いている窓 (全画面や左半分に寄せたとき)
///   - こちらが寄せた窓 (置いた場所に居る限り、こちらの持ち物として扱う)
///
/// 少し左寄りに置いただけの窓まで押しのけると、好きな場所に窓を置けなくなるし、
/// 動かすたびに押し返されて喧嘩になる。
///
/// 寄せた分は覚えておいて、サイドバーが引っ込むときに戻す。ただし
/// **人が自分でウィンドウを動かしていたら戻さない。** こちらが最後に置いた場所と
/// 違うなら、それは人の操作なので上書きしない。
///
/// 枠を読むのは CGWindowList (許可不要)、置き直すのは AppleScript (要オートメーション)。
/// 許可が無い環境では静かに何もしないだけで、吸着そのものは今までどおり動く。
///
/// **置き直した直後に CGWindowList を読んでも、まだ動く前の枠が返る。**
/// 効いたかどうかをその場で確かめる作りにすると、動いているのに
/// 「動かせなかった」と取り違えて、以後ずっと諦めてしまう。
///
/// 覚えていられるのは最後に寄せた1枚だけ。iTerm2 のウィンドウを2枚とも
/// 寄せた場合、戻せるのは後の1枚になる。
@MainActor
final class SidebarRoom {
    /// 詰めすぎて端末が読めなくならないための下限
    private let minimumTerminalWidth: CGFloat = 320
    /// 続けざまに Apple Event を投げない。追従は 60fps で回っているので、
    /// 素通しにすると1秒に何十回も iTerm2 を叩くことになる
    private let cooldown: TimeInterval = 0.5
    /// 動かしたと見なす許容差。iTerm2 は文字セル単位で大きさを丸めるので、
    /// 頼んだ位置ぴったりには収まらないことがある
    private let tolerance: CGFloat = 12
    /// 同じ枠を「動かなかった」と数えるまでの猶予。
    ///
    /// CGWindowList は少し遅れて更新されるので、置き直した直後はまだ古い枠が返る。
    /// すぐ数えると、動いているのに動かせなかったことにされて諦めてしまう
    private let staleGrace: TimeInterval = 2
    /// 寄せたのに元の枠へ戻される回数の上限。これを超えたら手を引く
    private let undoLimit = 3
    /// 手を引いている時間。押し合いを止めるのが目的なので、
    /// 人が状況を変えれば (別の枠を見れば) すぐ数え直す
    private let backoff: TimeInterval = 30

    /// 最後に寄せたときの (元の左端, 頼んだ左端)
    private var nudged: (original: CGFloat, applied: CGFloat)?
    private var lastAttempt = Date.distantPast

    /// 同じ枠に何回頼んだか。頼んでも動かない窓に何度も Apple Event を
    /// 投げ続けないよう、2回で諦める。違う枠を見たら数え直す
    private var requested: (bounds: CGRect, count: Int)?

    /// 寄せる直前に見えていた枠と、そこへ戻された回数。
    ///
    /// レイアウトを常時かけ直すウィンドウマネージャの下では、寄せる→最大化に
    /// 戻される→また寄せる、が延々続いてしまう。戻されたことを数えて、
    /// 続くようなら手を引く (人が窓を最大化し直した場合も同じ形に見えるが、
    /// そのときは少し待てば再開する)
    private var beforeNudge: CGRect?
    private var undoCount = 0
    private var backoffUntil = Date.distantPast

    /// 左に隙間が無ければ iTerm2 を右へ寄せる。
    ///
    /// - Parameters:
    ///   - bounds: iTerm2 のウィンドウ枠 (CGWindowList と同じ左上原点)
    ///   - screen: そのウィンドウが乗っている画面
    ///   - width: サイドバーの幅
    /// - Returns: 実際に動かしたら true。呼ぶ側は次の追従で枠を読み直す
    @discardableResult
    func makeRoom(itermBounds bounds: CGRect, screen: NSScreen, width: CGFloat) -> Bool {
        // Dock やメニューバーを避けた枠で考える。Dock が左にあるとき、
        // 最大化した窓の左端は画面の端ではなく Dock の右になる
        let leftLimit = screen.visibleFrame.minX
        let wanted = leftLimit + width

        // 画面いっぱい (メニューバーまで覆っている) のときは macOS のフルスクリーン。
        // 専用のスペースに居るのでウィンドウの枠を変えられない
        guard !isNativeFullScreen(bounds, screen: screen) else { return false }

        // こちらが置いた場所に居る窓は、端に張り付いていなくても自分の持ち物。
        // これを見ないと、サイドバーの幅を変えたときに寄せ直せない
        let isOurs = nudged.map { abs(bounds.minX - $0.applied) < tolerance } ?? false
        guard bounds.minX <= leftLimit + 2 || isOurs else { return false }
        // **動かすのは右へだけ。** サイドバーを狭めたときに窓を左へ引っぱると、
        // 頼んでもいない端末の幅が勝手に広がる。左に隙間が空くのは許容して、
        // 詰め直したい人は自分で最大化すればいい (窓を動かすのは人の領分)
        guard bounds.minX < wanted - 1 else { return false }
        guard bounds.maxX - wanted >= minimumTerminalWidth else { return false }

        // 手を引いている間は何もしない。明けたら数え直して、また2回までは試す
        guard Date() >= backoffUntil else { return false }
        if undoCount >= undoLimit { undoCount = 0 }

        guard Date().timeIntervalSince(lastAttempt) >= cooldown else { return false }

        // 頼んでも枠が変わらないなら、その窓は動かせない。
        // 同じ枠のまま3回目は投げない (違う枠を見たら数え直す。一度動いた窓が
        // 戻ってきたのは、動かせないことの証拠にはならない)。
        //
        // 同じ枠を数えるのは猶予を過ぎてから。置き直した直後の古い枠を
        // 「動かなかった」と数えると、動いているのに諦めてしまう
        if let requested, SidebarRoom.isSame(requested.bounds, bounds) {
            guard Date().timeIntervalSince(lastAttempt) >= staleGrace else { return false }
            guard requested.count < 2 else { return false }
            self.requested = (bounds, requested.count + 1)
        } else {
            requested = (bounds, 1)
        }
        lastAttempt = Date()

        // 前に寄せたときと同じ枠から寄せ直している = 前の寄せが押し戻された。
        // **数えるのは寄せる直前だけ。** 見かけるたびに数えると、追従が
        // 60fps で回っている間に一瞬で上限へ達してしまう
        if let beforeNudge, SidebarRoom.isSame(beforeNudge, bounds) {
            undoCount += 1
        } else {
            undoCount = 0
        }
        if undoCount >= undoLimit {
            backoffUntil = Date().addingTimeInterval(backoff)
            return false
        }

        // 元の左端は、こちらの窓なら覚えている分を引き継ぐ。
        // 寄せたあとの位置を「元の位置」にしてしまうと、戻す先が消える
        let original = isOurs ? (nudged?.original ?? bounds.minX) : bounds.minX

        let target = CGRect(x: wanted, y: bounds.minY,
                            width: bounds.maxX - wanted, height: bounds.height)
        guard ItermBridge.setCurrentWindowBounds(target) else { return false }
        beforeNudge = bounds
        nudged = (original: original, applied: wanted)
        return true
    }

    /// 寄せた分を戻す。サイドバーが引っ込むときと、アプリを終えるときに呼ぶ。
    func restore() {
        requested = nil
        beforeNudge = nil
        undoCount = 0
        backoffUntil = .distantPast
        guard let nudged else { return }
        self.nudged = nil

        // いまの枠を読んでから決める。人が動かしたあとなら触らない
        guard let bounds = SidebarRoom.currentItermBounds(),
              abs(bounds.minX - nudged.applied) < tolerance else { return }
        ItermBridge.setCurrentWindowBounds(
            CGRect(x: nudged.original, y: bounds.minY,
                   width: bounds.maxX - nudged.original, height: bounds.height))
    }

    /// もう一度試してよいことにする。人が幅を変えたときなど、
    /// 望む形が変わったときに呼ぶ。
    ///
    /// 手を引いていた分と諦めた分だけを消し、**寄せた記憶は残す**
    /// (元の幅に戻す先が消えてしまうため)。
    func retryNow() {
        requested = nil
        undoCount = 0
        backoffUntil = .distantPast
    }

    /// 寄せたことを忘れる。戻す相手がもう居ない (iTerm2 ごと終わった) ときに使う。
    ///
    /// **窓が一時的に見えないだけでは呼ばないこと。** CGWindowList は別スペースや
    /// 隠された窓を返さないので、スペースを切り替えるたびに忘れてしまい、
    /// あとで戻せなくなる。違う窓を動かしてしまう心配は restore 側の
    /// 「置いた場所に居るときだけ戻す」で足りている
    func forget() {
        nudged = nil
        requested = nil
        beforeNudge = nil
        undoCount = 0
        backoffUntil = .distantPast
    }

    // MARK: -

    /// メニューバーごと覆っていれば macOS のフルスクリーン。専用のスペースに
    /// 居るので枠を変えられない。ウィンドウマネージャで最大化しただけなら、
    /// メニューバーの分だけ下から始まるので見分けがつく。
    ///
    /// メニューバーを自動的に隠す設定では最大化との区別が付かず、寄せずに諦める。
    /// 誤って動かそうとしても Apple Event が2回飛んで終わる (requested が止める)
    private func isNativeFullScreen(_ bounds: CGRect, screen: NSScreen) -> Bool {
        bounds.height >= screen.frame.height - 1
    }

    /// 枠が実質同じか。丸めの誤差ぶんは同じものとして扱う
    private static func isSame(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) < 2 && abs(lhs.minY - rhs.minY) < 2
            && abs(lhs.width - rhs.width) < 2 && abs(lhs.height - rhs.height) < 2
    }

    /// その枠が一番多く乗っている画面。どこにも掛かっていなければ nil。
    ///
    /// **画面をメイン決め打ちにしないためにある。** 端末を別の画面に出していると、
    /// 左端 (visibleFrame.minX) も画面の高さも別物になるので、メイン画面の
    /// 物差しで測ると場所を空け損ねるし、置いたサイドバーが画面の外へ出る。
    ///
    /// 比べる前に NSScreen の枠を CGWindowList の向き (メイン画面の左上が原点で
    /// 下向き) に直す。x はどちらの座標系でも同じなので、直すのは y だけ
    static func screen(containing bounds: CGRect) -> NSScreen? {
        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in NSScreen.screens {
            // 交わらないときの intersection は null 矩形で、幅も高さも 0 になる
            let overlap = cgFrame(of: screen).intersection(bounds)
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        return best
    }

    /// NSScreen の枠を CGWindowList と同じ向きで表したもの。
    ///
    /// AppKit の原点はメイン画面の左下、CGWindowList はメイン画面の左上。
    /// **どの画面を映すときも引き算に使うのはメイン画面の高さ** で、
    /// その画面自身の高さではない (原点はメイン画面にあるため)
    private static func cgFrame(of screen: NSScreen) -> CGRect {
        guard let primary = NSScreen.screens.first else { return screen.frame }
        return CGRect(x: screen.frame.minX,
                      y: primary.frame.height - screen.frame.maxY,
                      width: screen.frame.width, height: screen.frame.height)
    }

    /// CGWindowList から最前面の iTerm2 のウィンドウ枠を読む。
    /// SidebarPanel と同じ見方をするので、判定もそこに合わせてある
    static func currentItermBounds() -> CGRect? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        for window in list {
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let layer = window[kCGWindowLayer as String] as? Int ?? -1
            guard owner == "iTerm2", layer == 0,
                  let box = window[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            let width = box["Width"] ?? 0
            let height = box["Height"] ?? 0
            if width >= 400 && height >= 300 {
                return CGRect(x: box["X"] ?? 0, y: box["Y"] ?? 0,
                              width: width, height: height)
            }
        }
        return nil
    }
}
