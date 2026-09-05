import AppKit
import Model

/// メニューバーに出す状態の見た目。
///
/// 一覧では絵文字 (⏳ ✅) を使っているが、メニューバーでは SF Symbols に置き換える。
/// 絵文字は字幅も色も OS 任せで、記号 (▶) と混ざると字面が揃わないうえ、
/// 数が変わるたびにバーの幅が動いて落ち着かない。
///
/// 状態の語彙そのものは Model の TaskStatus が正本で、
/// ここが決めるのは「メニューバーではどう描くか」だけ。
public enum StatusGlyph {
    /// 記号と数字の太さ。
    ///
    /// メニューバーは壁紙が透けるので、既定の太さだと細くて沈む。
    /// 記号と数字を別々に決めると字面がちぐはぐになるので、まとめてここで持つ。
    public static let weight: NSFont.Weight = .semibold

    /// 状態に対応する SF Symbol 名と色。
    ///
    /// 色は必ず決める。テンプレート画像にして OS に任せる手もあるが、
    /// **NSTextAttachment に入れた画像はテンプレートとして扱われない**ため、
    /// 地の色に関わらずラスタライズした色 (既定では黒) がそのまま出てしまう。
    ///
    /// - Parameter defaultTint: 状態そのものが色を持たないときに使う色。
    ///   メニューバーの地色に合わせたものを呼び出し側が解決して渡す
    public static func symbol(for status: String,
                              defaultTint: NSColor) -> (name: String, tint: NSColor) {
        switch status {
        case TaskStatus.waiting:
            // 手を挙げて待っている。ここだけ色を付けて目を引かせる
            return ("hand.raised.fill", .systemOrange)
        case TaskStatus.running:
            return ("play.fill", defaultTint)
        case TaskStatus.done:
            return ("checkmark", .systemGreen)
        case TaskStatus.seen:
            // 見終わったもの。色は落として、まだ見ていない完了と区別する
            return ("checkmark.circle", defaultTint.withAlphaComponent(0.55))
        case TaskStatus.failed:
            return ("xmark", .systemRed)
        case TaskStatus.missing:
            return ("exclamationmark.triangle.fill", .systemRed)
        default:
            return ("circle", defaultTint)
        }
    }

    /// 「記号 数」を1組ぶん作る。
    public static func attributed(status: String, count: Int, fontSize: CGFloat,
                                  defaultTint: NSColor) -> NSAttributedString {
        let (name, tint) = symbol(for: status, defaultTint: defaultTint)
        let line = NSMutableAttributedString()

        if let image = NSImage(systemSymbolName: name, accessibilityDescription:
                                TaskStatus.label(status)) {
            let config = NSImage.SymbolConfiguration(pointSize: fontSize,
                                                     weight: Self.weight)
            var sized = image.withSymbolConfiguration(config) ?? image
            // SF Symbols は記号ごとに幅が違う (play.fill は 12pt、hand.raised.fill は 16pt)。
            // そのまま並べると、状態が変わるたびにメニューバーの幅が動いて落ち着かない。
            // 決まった幅の中に中央寄せで描き直して揃える
            sized = sized.centered(inWidth: fontSize * 1.3).tinted(with: tint)

            let attachment = NSTextAttachment()
            attachment.image = sized
            // 既定だと画像がベースラインに乗って数字より上に浮く。少し沈めて高さを合わせる
            attachment.bounds = CGRect(x: 0, y: -fontSize * 0.12,
                                       width: sized.size.width, height: sized.size.height)
            line.append(NSAttributedString(attachment: attachment))
        } else {
            // SF Symbols が引けない場合の保険。一覧と同じ記号に戻す
            line.append(NSAttributedString(string: TaskStatus.mark(status),
                                           attributes: [.foregroundColor: tint]))
        }

        // 記号と数字をくっつけない。地続きだと1つの字のように見える
        line.append(NSAttributedString(string: " \(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: Self.weight),
            .foregroundColor: tint,
        ]))
        return line
    }

    /// メニューの項目の頭に出すアイコン。
    ///
    /// こちらは NSMenuItem.image なのでテンプレートが効く。
    /// 状態そのものが色を持つものだけ塗り、あとは OS に任せる。
    public static func menuIcon(for status: String) -> NSImage? {
        let (name, tint) = symbol(for: status, defaultTint: .labelColor)
        guard let image = NSImage(systemSymbolName: name,
                                  accessibilityDescription: TaskStatus.label(status))
        else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let sized = image.withSymbolConfiguration(config) ?? image
        // 状態固有の色を持たないものはテンプレートのままにして、地色に追従させる
        if tint == NSColor.labelColor {
            sized.isTemplate = true
            return sized
        }
        return sized.tinted(with: tint)
    }

    /// 知らせることが何も無いときの印。アプリのマーク (`AppMark`) を出す。
    ///
    /// 数字は出さない。出すべきものが無いことを、印1つで静かに示す。
    /// **項目ごと消してしまわないのは、メニューが設定とサイドバー切替と終了の
    /// 唯一の入口だから。** 見張っているのに姿が無いと、生きているのかも分からない。
    /// ここをアイコンにしているのは、そのときだけメニューバーに出ている物が
    /// 何なのか分からなくなるため。動きがあるときは状態の記号に譲る。
    ///
    /// 色は数字と同じ地色 (メニューバーの文字色) をそのまま使う。薄くすると
    /// 壁紙が透ける場所で沈んで見えなくなる。白と決め打ちにしないのは、
    /// メニューバーが明るいときに見えなくなるため
    public static func idleLine(fontSize: CGFloat = 13,
                                defaultTint: NSColor) -> NSAttributedString {
        let image = AppMark.image(height: fontSize * markScale, tint: defaultTint)
        let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: Self.weight)

        let attachment = NSTextAttachment()
        attachment.image = image
        // 画像の下端を書体の下がり (descender) にそろえる。
        //
        // **こうしないと印が上に寄る。** ボタンは行をまるごと中央に置くが、
        // 行の高さは書体の上がり下がりからも決まる。画像をベースラインの近くに
        // 置くと行の下端だけが書体のぶん下に伸び、その差が下の余白になる。
        // そろえれば行の高さ = 画像の高さになり、行の中央 = 画像の中央になる
        attachment.bounds = CGRect(x: 0, y: font.descender,
                                   width: image.size.width, height: image.size.height)

        let line = NSMutableAttributedString(attachment: attachment)
        // 書体を明示する。決めないと既定の書体の上がり下がりで行の高さが決まり、
        // 文字の大きさを変えても印の位置がついてこない
        line.addAttribute(.font, value: font,
                          range: NSRange(location: 0, length: line.length))
        return line
    }

    /// 印の高さ。文字より少し大きくする。
    ///
    /// 角帽・頭・肩が縦に積み重なる絵なので、文字と同じ高さでは
    /// それぞれの隙間が潰れて1つの塊に見える。
    /// これ以上大きくするとメニューバー (22pt ほど) の上下が詰まる
    private static let markScale: CGFloat = 1.3

    /// 要約をまるごと1行にする。組と組の間は文字の間より広く空ける
    public static func summaryLine(_ summary: [(status: String, count: Int)],
                                   fontSize: CGFloat = 13,
                                   defaultTint: NSColor) -> NSAttributedString {
        let line = NSMutableAttributedString()
        for (index, entry) in summary.enumerated() {
            if index > 0 {
                line.append(NSAttributedString(string: "   "))
            }
            line.append(attributed(status: entry.status, count: entry.count,
                                   fontSize: fontSize, defaultTint: defaultTint))
        }
        return line
    }
}

private extension NSImage {
    /// 決まった幅の中に中央寄せで描き直す。記号ごとの幅の違いを吸収する
    func centered(inWidth width: CGFloat) -> NSImage {
        guard size.width < width else { return self }
        let box = NSSize(width: width, height: size.height)
        let copy = NSImage(size: box, flipped: false) { _ in
            self.draw(in: NSRect(x: (width - self.size.width) / 2, y: 0,
                                 width: self.size.width, height: self.size.height))
            return true
        }
        copy.isTemplate = isTemplate
        return copy
    }

    /// 色を塗る。SF Symbols はそのままだと黒で描かれる
    func tinted(with color: NSColor) -> NSImage {
        let copy = NSImage(size: size, flipped: false) { rect in
            color.set()
            self.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        copy.isTemplate = false
        return copy
    }
}
