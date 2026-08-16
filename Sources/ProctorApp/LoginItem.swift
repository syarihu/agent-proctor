import Foundation
import ServiceManagement

/// ログイン時の自動起動。
///
/// もともと iTerm2 の AutoLaunch が担っていた「端末を開いたら勝手に居る」を
/// 引き継ぐもの。アプリ単体で立つようになった以上、自分で登録する必要がある。
@MainActor
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// - Throws: 登録に失敗した理由。呼び出し側が人に見せる
    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
