import AppKit

/// メニューバーに出すアプリの印。ロゴの試験監督を、メニューバーの大きさで描き直す。
///
/// **ロゴの PNG は縮めて使えない。** 線幅が絵の高さの 2.4% しかなく、
/// メニューバーに収まる大きさでは線が 1px を切って灰色に溶ける。
///
/// アイコンの試験監督から取ったのは、角帽 (板と山と房)・頭・肩の3つ。
/// 笛や襟まで入れると 17pt では団子になるが、この3つは輪郭だけで意味が立つ。
///
/// **バインダーは足さない。** アイコンでは胸の前に抱えているが、塗り分けの無い
/// シルエットでは「胴体に空いた四角」にしかならない。縦長にしても留め具を
/// 付けても同じで、留め具はこの大きさでは本体とくっついて消える。
///
/// 線ではなく塗りで描く。この印と入れ替わりに同じ場所へ出る状態の記号が
/// `hand.raised.fill` のような塗りの SF Symbols なので、線画にすると
/// 印のときだけ細く見えて落ち着かない。
enum AppMark {
    /// 角帽の板の幅。頭より広く取らないと、ひさしが出ずに帽子に見えない。
    /// 板が印の中で一番広いので、この値がそのまま印の幅になる
    private static let boardWidthRatio: CGFloat = 0.96
    /// 板そのものの厚み (ひし形の高さ)
    private static let boardThickRatio: CGFloat = 0.15

    /// 板の下の、頭にかぶさる部分。
    /// **これが無いと板が宙に浮いたひし形にしか見えず、角帽に読めない。**
    /// 帽子らしさはひさしより、頭に乗っている山のほうが効く
    private static let crownHeightRatio: CGFloat = 0.13
    private static let crownWidthRatio: CGFloat = 0.36

    /// 頭の半径。山に隠れるので、見えるのは下半分だけになる
    private static let headRadiusRatio: CGFloat = 0.175

    /// 肩の半円の半径。角帽の板より狭くする。
    /// 広いとひさしが肩に隠れて、輪郭が寸胴になる
    private static let shoulderRadiusRatio: CGFloat = 0.40

    private static let tasselLengthRatio: CGFloat = 0.26
    private static let tasselWidthRatio: CGFloat = 0.07

    /// 重なる物どうしの間に空ける隙間。
    /// 壁紙が透けるメニューバーでは地色で塗り潰せないので、切り抜いて空ける
    private static let gapRatio: CGFloat = 0.055

    /// 高さ `height` の印を、`tint` で塗って描く。
    ///
    /// テンプレート画像にはしない。`NSTextAttachment` に入れた画像は
    /// テンプレートとして扱われず、地色に関わらず黒で出てしまうため
    static func image(height: CGFloat, tint: NSColor) -> NSImage {
        let boardW = height * boardWidthRatio
        let boardH = height * boardThickRatio
        let crownH = height * crownHeightRatio
        let crownW = height * crownWidthRatio
        let headR = height * headRadiusRatio
        let shoulderR = height * shoulderRadiusRatio
        let gap = height * gapRatio

        let size = NSSize(width: boardW, height: height)
        let cx = boardW / 2

        // 位置は上から決めていく (描く順は逆で、下にある物から塗る)
        let boardMidY = height - boardH / 2
        let crownBottom = boardMidY - boardH / 2 - crownH
        // 頭は山に少し食い込ませる。離すと首が伸びて見える
        let headY = crownBottom - headR * 0.35

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.setFillColor(tint.cgColor)

            // 下から順に描き、上に乗る物の場所は隙間ごと切り抜いていく。
            // 地色で塗り潰す手もあるが、メニューバーは壁紙が透けるので
            // 塗ると四角い影になってしまう

            // 肩。下端で切れる半円にする。人の形は肩の曲線だけで伝わるので、
            // 胴を伸ばして印を縦に長くする必要はない
            ctx.addArc(center: CGPoint(x: cx, y: 0), radius: shoulderR,
                       startAngle: 0, endAngle: .pi, clockwise: false)
            ctx.closePath()
            ctx.fillPath()

            // 今の比率では肩は頭まで届かないので、この切り抜きは何も消さない。
            // それでも残してあるのは、肩を広げたときに頭が肩に埋まらないため
            ctx.punch(circle: CGPoint(x: cx, y: headY), radius: headR + gap)
            ctx.addEllipse(in: CGRect(x: cx - headR, y: headY - headR,
                                      width: headR * 2, height: headR * 2))
            ctx.fillPath()

            // 角帽は板・山・房をひとつの塊として組む。
            // **別々に隙間を空けてはいけない。** 房を切り離すと、板から浮いた
            // 短い棒になってゴミが乗っているように見える。
            //
            // **どの部分も反時計回りで組むこと。** 塗りは nonzero なので、
            // 巻き方向が逆の部分どうしが重なると打ち消し合って穴になる。
            // 房と玉に使う addRoundedRect / addEllipse が反時計回りなので、
            // 手で組む板と山もそれに合わせる
            let cap = CGMutablePath()
            cap.move(to: CGPoint(x: 0, y: boardMidY))
            cap.addLine(to: CGPoint(x: cx, y: boardMidY - boardH / 2))
            cap.addLine(to: CGPoint(x: boardW, y: boardMidY))
            cap.addLine(to: CGPoint(x: cx, y: height))
            cap.closeSubpath()

            // 山の上辺は板の下端より少し上 (boardH * 0.2) に置いて、板に食い込ませる。
            // ちょうど揃えると接するだけになり、1つの塊として繋がらない。
            // 上辺を下辺より狭める (0.86) のは、頭に向けて少しすぼめるため
            let crownTop = boardMidY - boardH / 2 + boardH * 0.2
            cap.move(to: CGPoint(x: cx - crownW / 2 * 0.86, y: crownTop))
            cap.addLine(to: CGPoint(x: cx - crownW / 2, y: crownBottom))
            cap.addLine(to: CGPoint(x: cx + crownW / 2, y: crownBottom))
            cap.addLine(to: CGPoint(x: cx + crownW / 2 * 0.86, y: crownTop))
            cap.closeSubpath()

            let tasselW = height * tasselWidthRatio
            let tasselL = height * tasselLengthRatio
            // 板の右端の内側から下ろす。端ちょうどだと板が尖っていて接点が細く、
            // 切れて見える
            let tasselX = boardW - tasselW * 1.1
            cap.addRoundedRect(in: CGRect(x: tasselX - tasselW / 2, y: boardMidY - tasselL,
                                          width: tasselW, height: tasselL),
                               cornerWidth: tasselW / 2, cornerHeight: tasselW / 2)
            cap.addEllipse(in: CGRect(x: tasselX - tasselW * 0.85,
                                      y: boardMidY - tasselL - tasselW * 0.7,
                                      width: tasselW * 1.7, height: tasselW * 1.7))

            ctx.punch(path: cap, widenBy: gap)
            ctx.addPath(cap)
            ctx.fillPath()

            return true
        }
        return image
    }
}

private extension CGContext {
    /// すでに描いたものを、その形のぶんだけ消す
    func punch(circle center: CGPoint, radius: CGFloat) {
        saveGState()
        setBlendMode(.clear)
        addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
        fillPath()
        restoreGState()
    }

    /// 経路の形を、周りに `widenBy` だけ広げて消す。
    ///
    /// 太さ `widenBy * 2` の線で縁取った形を塗ることで、輪郭から `widenBy` だけ
    /// はみ出した形を得ている。ただし縁取りは帯でしかなく内側が空くので、
    /// 元の形も続けて塗らないと真ん中が消え残る
    func punch(path: CGPath, widenBy: CGFloat) {
        saveGState()
        setBlendMode(.clear)
        addPath(path.copy(strokingWithWidth: widenBy * 2, lineCap: .round,
                          lineJoin: .round, miterLimit: 10))
        fillPath()
        addPath(path)
        fillPath()
        restoreGState()
    }
}
