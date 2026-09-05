import Foundation
import Model
import RepositoryLedger
import Utility

/// 閉じられたタブや終了したプロセスのタスク記録を台帳から削除する。
/// タブ終了時に SessionEnd フックが実行されない場合があるため、プロセスの生死および端末セッション一覧と照合して回収する。
public enum ReapClosedSessions {
    /// - Parameter aliveSessionIDs: 現在端末で開かれているセッション ID の集合。
    ///   取得失敗時は誤削除を防ぐため空の集合を渡し、端末との照合をスキップする（PID による照合のみ実行）。
    /// - Parameter isAlive: プロセスの生存判定クロージャ（テスト用に注入可能）
    /// - Returns: 台帳から削除されたタスク ID のリスト
    @discardableResult
    public static func reap(
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
