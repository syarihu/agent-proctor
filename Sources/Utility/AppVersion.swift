import Foundation

/// 自分がどの版かを答える。
///
/// 版の出どころは repo 直下の `VERSION` で、`scripts/build-app.sh` がそれを
/// `.app` の Info.plist に焼き込む。ここは焼かれた結果を読むだけにしている。
/// ソースに版を書き写さないのは、書いた瞬間に `VERSION` と二重管理になり、
/// どちらかを直し忘れて食い違うため。
public enum AppVersion {
    /// 表示用の版。`.app` の外から走らせているときは nil。
    ///
    /// nil を「不明」として扱えるようにしているのは、`.build/release` から
    /// 直に走らせた開発中のビルドに、それらしい版を名乗らせないため。
    /// 版を聞かれて嘘を答えると、不具合の報告が当てにならなくなる。
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
