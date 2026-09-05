import Foundation

/// ローカライズ文字列の取得窓口。リソース定義は Resources/{en,ja}.lproj/Localizable.strings。
///
/// 各レイヤーから横断的に利用されるため基盤モジュールに配置する。
/// CLI とアプリで文言の一貫性を保つため同一リソースを参照する。
public enum Localized {
    /// SwiftPM が生成するリソースバンドル名
    private static let bundleNames = [
        "proctor_Resources.bundle",
    ]

    /// 適切な言語リソース (.lproj) バンドルの解決。
    ///
    /// CLI 単体バイナリでは主バンドルに言語定義が存在せず `NSLocalizedString` の自動解決が常に英語になるため、
    /// `Locale.preferredLanguages` を基に対象言語の .lproj バンドルを明示的に探索する。
    private static let table: Bundle? = {
        guard let source = source else { return nil }
        let best = Bundle.preferredLocalizations(
            from: source.localizations, forPreferences: Locale.preferredLanguages).first
        guard let best,
              let path = source.path(forResource: best, ofType: "lproj") else { return source }
        return Bundle(path: path) ?? source
    }()

    /// .lproj を保持するリソースバンドルを探索する。配置パターンが3通りあるため順に検索する。
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
        // 実行ファイルがシンボリックリンク経由（~/bin/proctor など）でも解決できるよう実体パスを参照する。
        // argv[0] ではなく executablePath を使用するのは、PATH 解決等により
        // argv[0] が単なるコマンド名（"proctor"）となった場合でも自身の実行ファイルパスを特定できるようにするため
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
