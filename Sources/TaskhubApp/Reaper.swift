import Foundation
import TaskhubKit

/// 閉じられたタブの記録を片付ける。
///
/// タブを閉じると claude 本体ごと終わるため、SessionEnd の hook が
/// 書き終わる前に殺されて記録が残ることがある。hook の到達を当てにせず、
/// iTerm2 にセッションが残っているかどうかで判断する。
///
/// iTerm2 のセッションIDを持たないもの (ssh 越しなど) は生死が分からないので
/// 触らない。それらは taskhub 側の期限切れ (Hooks.pruneSessions) で落ちる。
@MainActor
final class Reaper {
    /// 反応が遅れても困らないので長めに取る
    private let interval: TimeInterval = 30
    private var timer: Timer?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in Reaper.sweep(onChange: onChange) }
        }
    }

    deinit { timer?.invalidate() }

    private static func sweep(onChange: () -> Void) {
        // 取得に失敗したときに全部消してしまわないための保険。
        // nil は「分からなかった」であって「1つも無い」ではない
        guard let alive = ItermBridge.liveSessionIDs(), !alive.isEmpty else { return }

        let dead = Ledger.loadTasks()
            .filter { task in
                task.isSession
                    && (task.itermSession.map { !alive.contains($0) } ?? false)
            }
            .map(\.id)

        guard !dead.isEmpty else { return }
        try? Ledger.drop(ids: dead)
        onChange()
    }
}
