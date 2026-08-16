import Foundation

/// 閉じられたタブの記録を片付ける。
///
/// タブを閉じると claude 本体ごと終わるため、SessionEnd の hook が
/// 書き終わる前に殺されて記録が残ることがある。hook の到達を当てにせず、
/// 端末に生きているセッションと突き合わせて判断する。
///
/// 生きているIDをどこから取るかは環境によって違う (iTerm2 なら AppleScript) ので、
/// 外から渡してもらう。ここが持つのは「どれを消してよいか」の判断だけ。
public enum ReapClosedSessions {
    /// - Parameter aliveSessionIDs: いま端末に開いているセッションのID。
    ///   **取得に失敗したときは呼ばないこと。** 空の集合を渡すと、
    ///   一時的に取れなかっただけなのに全部消してしまう。
    /// - Returns: 台帳から外した ID
    @discardableResult
    public static func run(aliveSessionIDs alive: Set<String>) throws -> [String] {
        guard !alive.isEmpty else { return [] }

        // 端末のセッションIDを持たないもの (ssh 越しなど) は生死が分からないので
        // 触らない。それらは RecordHookEvent の期限切れで落ちる
        let dead = LedgerStore.tasks()
            .filter { task in
                guard task.isSession, let iterm = task.itermSession else { return false }
                return !alive.contains(iterm)
            }
            .map(\.id)

        guard !dead.isEmpty else { return [] }
        try LedgerStore.drop(ids: dead)
        return dead
    }
}
