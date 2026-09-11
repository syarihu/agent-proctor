import Foundation

/// サイドバーの見せ方。同じ台帳を一覧で読むか、作業場の俯瞰で眺めるか。
///
/// `GroupingMode` (同じ一覧をどう束ねるか) とは軸が違うので別の enum にしている。
/// あちらに case を足すと `resolvedGrouping` や `TaskGrouping.pending` といった
/// 「束ね方」を前提にした場所へ、束ね方ではないものが流れ込む
public enum SidebarMode: String, CaseIterable, Sendable {
    /// 1行1セッションの一覧
    case list
    /// 机を並べた作業場の俯瞰
    case desk
}
