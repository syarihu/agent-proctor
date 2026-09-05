import Foundation
import ServiceManagement

/// ログイン時の自動起動（SMAppService）の管理。
@MainActor
public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// ログイン項目の有効・無効を設定する
    public static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
