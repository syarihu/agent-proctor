import AppKit

/// メニューバーに表示するアプリシンボル。
///
/// メニューバーサイズ（約17pt）では元ロゴの極細線（高さ比2.4%）が1px未満となり視認できないため、
/// 角帽・頭・肩のシルエットのみをベクターパスで再描画する。
/// 細かいディテール（笛や襟、バインダー等）は視認性を保つため省いている。
/// また、SF Symbolsの塗り潰し記号（hand.raised.fill 等）と並んでも違和感がないよう、線画ではなく塗りで描画する。
public enum AppMark {
    /// 角帽の天板の幅（シンボル全体の最大幅）
    private static let boardWidthRatio: CGFloat = 0.96
    /// 天板の厚み比率
    private static let boardThickRatio: CGFloat = 0.15

    /// 天板の下のクラウン（頭にかぶさる部分）の比率
    private static let crownHeightRatio: CGFloat = 0.13
    private static let crownWidthRatio: CGFloat = 0.36

    /// 頭部の半径比率
    private static let headRadiusRatio: CGFloat = 0.175

    /// 肩の半円の半径比率（天板のひさしが隠れないよう天板より狭くする）
    private static let shoulderRadiusRatio: CGFloat = 0.40

    private static let tasselLengthRatio: CGFloat = 0.26
    private static let tasselWidthRatio: CGFloat = 0.07

    /// 重なる要素間の余白比率（透過メニューバーで背景色塗り潰しが使えないため切り抜きで表現）
    private static let gapRatio: CGFloat = 0.055

    /// 高さ `height` の印を、`tint` で塗って描く。
    ///
    /// テンプレート画像にはしない。`NSTextAttachment` に入れた画像は
    /// テンプレートとして扱われず、地色に関わらず黒で出てしまうため
    public static func image(height: CGFloat, tint: NSColor) -> NSImage {
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

            // 角帽（天板・クラウン・房）は1つのパスとして組む。
            // 塗りは nonzero 規則のため、パーツ間の巻き方向が逆だと重なり部分が穴になる。
            // addRoundedRect / addEllipse が反時計回りのため、天板とクラウンも反時計回りに揃える。
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
