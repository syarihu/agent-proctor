import Foundation

/// 表に出る言葉の取り出し口。訳文は Resources/{en,ja}.lproj/Localizable.strings。
///
/// 3層 (Model / Repository / UseCase) のどれにも入れていないのは、
/// どの層からも使うため。中身は静的な表の読み出しだけで、判断も台帳への出入りもしない。
///
/// CLI とアプリで別々に持たないのは、同じ言葉を2か所で訳すと必ずずれるから。
/// 表示の**色**は View 側 (Terminal / Palette) が持つという分担は変わらない。
/// ここが持つのは「何と呼ぶか」までで、TaskStatus と同じ線引きにしている。
public enum Localized {
    /// SwiftPM が作るリソースバンドルの名前 (パッケージ名_ターゲット名)
    private static let bundleNames = [
        "proctor_Resources.bundle",
    ]

    /// 訳文の入った .lproj を1つだけ選んで持っておく。
    ///
    /// **言語を自分で選んでいる理由。**
    /// `NSLocalizedString` に任せると、.app ではない実行ファイル (= CLI) では
    /// 主バンドルに言語が無いために `preferredLocalizations` が常に ["en"] を返し、
    /// システムが日本語でも英語が出てしまう。
    /// `Locale.preferredLanguages` は素直に ja-JP を返すので、そこから選び直す。
    /// システム設定の「アプリごとの言語」もこちらに乗るので、切り替えはそのまま効く。
    private static let table: Bundle? = {
        guard let source = source else { return nil }
        let best = Bundle.preferredLocalizations(
            from: source.localizations, forPreferences: Locale.preferredLanguages).first
        guard let best,
              let path = source.path(forResource: best, ofType: "lproj") else { return source }
        return Bundle(path: path) ?? source
    }()

    /// .lproj を抱えている入れ物を探す。置かれ方が3通りあるので順に当たる。
    ///
    /// 1. `.app` から起動したアプリ本体 … Contents/Resources に .lproj がある。
    ///    ここに置くのは、そうしないと macOS がこのアプリを「訳のあるアプリ」と見なさず、
    ///    システム設定の「アプリごとの言語」に出てこないため
    /// 2. `.app` に同梱した CLI … 自分は Contents/Helpers にいるので、隣の
    ///    Contents/Resources を見る。CLI の隣に .lproj を置くと codesign が
    ///    それを入れ子のバンドルと解釈して署名に失敗するため、置き場は1つにしている
    /// 3. ビルドディレクトリから直に走らせたとき … SwiftPM が作った .bundle が隣にいる
    private static let source: Bundle? = {
        var candidates: [Bundle?] = [.main]
        // 実行ファイルが symlink 越し (~/bin/proctor) でも辿れるように実体も見る。
        // argv[0] ではなく executablePath なのは、PATH 解決で名前だけ渡して
        // spawn されると argv[0] が "proctor" になり、自分の居場所を辿れないため
        // (Paths.appBundle も同じ理由で同じものを見ている)
        let executable = URL(fileURLWithPath:
            Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent()
        let siblingResources = executable.appendingPathComponent("../Resources").standardized
        for directory in [Bundle.main.bundleURL, Bundle.main.resourceURL,
                          executable, siblingResources].compactMap({ $0 }) {
            candidates.append(Bundle(url: directory))
            for name in bundleNames {
                candidates.append(Bundle(url: directory.appendingPathComponent(name)))
            }
        }
        return candidates.first { hasTable($0) } ?? nil
    }()

    private static func hasTable(_ bundle: Bundle?) -> Bool {
        bundle?.url(forResource: "Localizable", withExtension: "strings",
                    subdirectory: nil, localization: "en") != nil
    }

    /// 訳文を引く。見つからなければ鍵をそのまま返す
    /// (リソースを配り忘れたときに黙って空文字になるより、鍵が見えたほうが直せる)。
    public static func text(_ key: String) -> String {
        guard let table else { return key }
        return NSLocalizedString(key, bundle: table, value: key, comment: "")
    }

    /// 差し込みのある訳文。語順は言語で変わるので、訳文側は %1$@ で位置を指定できる
    public static func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: .current, arguments: arguments)
    }

    /// 訳文と同じ置き場から、まとまった文書を1つ読む。
    ///
    /// 文言の表と違って、これは丸ごと1つの読み物 (エージェントに渡す手引き)。
    /// 表に収めると改行だらけの1行になって手が入れられないので、ファイルのまま持つ。
    /// 言語の選び方は文言とまったく同じなので、選んである .lproj からそのまま読む。
    public static func document(_ name: String, extension ext: String = "md") -> String? {
        guard let table, let url = table.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text
    }
}
