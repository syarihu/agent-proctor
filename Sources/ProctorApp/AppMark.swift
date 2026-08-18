import AppKit

/// メニューバーに出すアプリの印。ロゴと同じ絵柄を、メニューバーの大きさで描き直す。
///
/// **ロゴの PNG は縮めて使えない。** 線幅が絵の高さの 2.4% しかなく、
/// メニューバーに収まる大きさでは線が 1px を切って灰色に溶ける。線だけ太らせると、
/// 今度は窓と窓の隙間 (線の 3 倍しかない) が埋まって 3 枚が団子になる。
///
/// なので線幅と重なりの間隔だけは、隣に並ぶ SF Symbols (semibold) と
/// 見比べて沈まない比率に取り直してある。
enum AppMark {
    /// 線の太さ。印の高さに対する割合。
    /// 元絵は 0.024。SF Symbols の semibold と釣り合うところまで太らせている
    private static let strokeRatio: CGFloat = 0.075
    /// 窓を1枚ぶんずらす量。手前の窓の線と奥の窓の線が地続きに見えない幅が要る
    private static let stepRatio: CGFloat = 0.165
    /// 手前にある物の周りに空ける隙間。
    /// 壁紙が透けるメニューバーでは地色で塗り潰せないので、切り抜いて空ける
    private static let gapRatio: CGFloat = 0.05

    /// 窓の横幅と高さの比 (ロゴの手前の窓 568x534 から)
    private static let windowAspect: CGFloat = 1.06

    /// 高さ `height` の印を、`tint` の線で描く。
    ///
    /// テンプレート画像にはしない。`NSTextAttachment` に入れた画像は
    /// テンプレートとして扱われず、地色に関わらず黒で出てしまうため
    static func image(height: CGFloat, tint: NSColor) -> NSImage {
        let stroke = height * strokeRatio
        let step = height * stepRatio
        let gap = height * gapRatio
        // 線は経路の両側に半分ずつはみ出すので、その分だけ図形を内側に取る
        let winH = height - stroke - step * 2
        let winW = winH * windowAspect
        let radius = winH * 0.17

        // 経路の中心で組む。原点は奥の窓の左端・手前の窓の下端
        let windows = (0..<3).map { i in
            CGRect(x: CGFloat(i) * step, y: CGFloat(2 - i) * step,
                   width: winW, height: winH)
        }
        let front = windows[2]
        // 確認済みの丸は、ロゴの比 (0.17) では中のチェックが点に潰れる。
        // 丸の中に折れ線が読める大きさまで広げてある
        let badgeRadius = winH * 0.30
        let badge = CGPoint(x: front.maxX - winW * 0.05,
                            y: front.maxY - winH * 0.16)

        // 印が丸をはみ出すぶんまで含めた大きさ。切り取られると丸が欠ける
        let content = windows[0].union(front)
            .union(CGRect(x: badge.x - badgeRadius, y: badge.y - badgeRadius,
                          width: badgeRadius * 2, height: badgeRadius * 2))
        let size = NSSize(width: content.width + stroke, height: content.height + stroke)

        let image = NSImage(size: size, flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.translateBy(x: stroke / 2 - content.minX, y: stroke / 2 - content.minY)
            ctx.setLineWidth(stroke)
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            ctx.setStrokeColor(tint.cgColor)

            // 奥から手前へ。手前の物を描く前に、その物が乗る場所を隙間ごと
            // 切り抜く。地色で塗り潰す手もあるが、メニューバーは壁紙が透けるので
            // 塗ると四角い影になってしまう
            for (index, window) in windows.enumerated() {
                if index > 0 {
                    ctx.punch(roundedRect: window.insetBy(dx: -(stroke / 2 + gap),
                                                          dy: -(stroke / 2 + gap)),
                              radius: radius + stroke / 2 + gap)
                }
                ctx.addPath(CGPath(roundedRect: window, cornerWidth: radius,
                                   cornerHeight: radius, transform: nil))
                ctx.strokePath()
            }

            // タイトルバーの線。手前の1枚にだけ入れる。奥の2枚は角しか見えず、
            // そこに短い線を足しても点にしかならない
            let titleBar = front.maxY - winH * 0.26
            ctx.move(to: CGPoint(x: front.minX, y: titleBar))
            ctx.addLine(to: CGPoint(x: front.maxX, y: titleBar))
            ctx.strokePath()

            // 確認済みの印
            ctx.punch(circle: badge, radius: badgeRadius + stroke / 2 + gap)
            ctx.addEllipse(in: CGRect(x: badge.x - badgeRadius, y: badge.y - badgeRadius,
                                      width: badgeRadius * 2, height: badgeRadius * 2))
            ctx.strokePath()

            let r = badgeRadius
            ctx.move(to: CGPoint(x: badge.x - r * 0.48, y: badge.y + r * 0.06))
            ctx.addLine(to: CGPoint(x: badge.x - r * 0.14, y: badge.y - r * 0.32))
            ctx.addLine(to: CGPoint(x: badge.x + r * 0.48, y: badge.y + r * 0.38))
            ctx.strokePath()

            return true
        }
        return image
    }
}

private extension CGContext {
    /// すでに描いたものを、その形のぶんだけ消す
    func punch(roundedRect rect: CGRect, radius: CGFloat) {
        saveGState()
        setBlendMode(.clear)
        addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                       transform: nil))
        fillPath()
        restoreGState()
    }

    func punch(circle center: CGPoint, radius: CGFloat) {
        saveGState()
        setBlendMode(.clear)
        addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                              width: radius * 2, height: radius * 2))
        fillPath()
        restoreGState()
    }
}
