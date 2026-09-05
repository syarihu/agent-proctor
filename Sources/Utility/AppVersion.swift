import Foundation

/// アプリケーションおよび CLI のバージョン情報。
///
/// バージョンはリポジトリ直下の `VERSION` を正本とし、ビルド時に Info.plist に埋め込まれる。
/// 二重管理による不整合を防ぐため、ソースコード内にバージョンを保持せず plist から読み込む。
public enum AppVersion {
    /// 表示用バージョン。`.app` バンドル外から直接実行された開発用ビルドでは nil を返す。
    public static let current: String? = {
        // アプリ本体は自分自身が .app なので、これで取れる
        if let version = Bundle.main.infoDictionary?[key] as? String, !version.isEmpty {
            return version
        }
        // 同梱の CLI は .app の中にいるが、自分はバンドルではないので
        // Bundle.main からは取れない。入っているバンドルの plist を直に読む
        guard let bundle = Paths.enclosingAppBundle,
              let plist = NSDictionary(contentsOf:
                bundle.appendingPathComponent("Contents/Info.plist")),
              let version = plist[key] as? String, !version.isEmpty else { return nil }
        return version
    }()

    private static let key = "CFBundleShortVersionString"
}
