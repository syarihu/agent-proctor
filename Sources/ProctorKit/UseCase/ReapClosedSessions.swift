import Foundation

/// 閉じられたタブの記録を片付ける。
///
/// タブを閉じると claude 本体ごと終わるため、SessionEnd の hook が
/// 書き終わる前に殺されて記録が残ることがある。hook の到達を当てにせず、
/// 実際に生きているかどうかと突き合わせて判断する。
///
/// 見方は2つある。**プロセスが分かるものはそれで決める**。端末が何であれ
/// 効くうえ、iTerm2 に聞く必要もない。分からないものだけ、端末に開いている
/// セッションと突き合わせる。生きているIDをどこから取るかは環境によって違う
/// (iTerm2 なら AppleScript) ので、外から渡してもらう。
/// ここが持つのは「どれを消してよいか」の判断だけ。
public enum ReapClosedSessions {
    /// - Parameter aliveSessionIDs: いま端末に開いているセッションのID。
    ///   **取得に失敗したときは空の集合を渡すこと。** 一時的に取れなかっただけなのに
    ///   全部消してしまわないよう、空のときは端末との突き合わせを見送る
    ///   (プロセスで分かるものは、それとは関係なく片付ける)。
    /// - Parameter isAlive: プロセスの生死。差し替えられるようにしてあるのは試験のため。
    /// - Returns: 台帳から外した ID
    @discardableResult
    public static func run(
        aliveSessionIDs alive: Set<String>,
        isAlive: (Int, Int?) -> Bool = { ProcessLiveness.isAlive(pid: $0, startedAt: $1) }
    ) throws -> [String] {
        let dead = LedgerStore.tasks()
            .filter { task in
                // プロセスが分かるなら、それが答え。端末を問わない
                if let pid = task.pid { return !isAlive(pid, task.pidStartedAt) }
                // 端末のセッションIDも持たないもの (ssh 越しなど) は生死が分からないので
                // 触らない。それらは RecordHookEvent の期限切れで落ちる
                guard !alive.isEmpty, let iterm = task.itermSession else { return false }
                return !alive.contains(iterm)
            }
            .map(\.id)

        guard !dead.isEmpty else { return [] }
        try LedgerStore.drop(ids: dead)
        return dead
    }
}
