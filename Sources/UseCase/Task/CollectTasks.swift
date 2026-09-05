import Foundation
import Model
import RepositoryGit
import RepositoryLedger

/// 台帳に動的な情報（Git 差分、存在確認、経過時間等）を付与して集計する。
/// CLI や UI 側の共通エントリポイントであり、表示側に集計ロジックが分散するのを防ぐ。
public enum CollectTasks {
    /// - Parameters:
    ///   - repo: 指定したリポジトリのみに絞り込む場合に使用。allRepos が true の場合は無視される
    ///   - allRepos: 全リポジトリを対象にする
    ///   - itermOnly: iTerm2 で開けるセッションのみに絞り込む
    ///   - withOrigin: リモートリポジトリ情報（GitHub 等）の解決を行うかどうか。
    ///     git remote 呼び出しを伴うため、CLI 等で不要な場合は false にしてコストを抑制する。
    ///   - countDiff: 未コミットの変更差分を集計するかどうか。
    ///     無効な場合は DiffCounts() (差分 0) を設定する。
    public static func collect(repo: String? = nil, allRepos: Bool = false,
                               itermOnly: Bool = false,
                               withOrigin: Bool = false,
                               countDiff: Bool = true) -> [CollectedTask] {
        var records = LedgerStore.tasks()
        if !allRepos, let repo {
            records = records.filter { $0.repo == repo }
        }
        if itermOnly {
            records = records.filter(\.isItermManaged)
        }

        let now = Int(Date().timeIntervalSince1970)
        return ordered(records).map { record in
            let exists = FileManager.default.fileExists(atPath: record.worktree)
            return CollectedTask(
                record: record,
                repoName: URL(fileURLWithPath: record.repo).lastPathComponent,
                origin: withOrigin ? ResolveRepoOrigin.resolve(repo: record.repo) : nil,
                exists: exists,
                // 作業ディレクトリが手動削除された場合、台帳上は残存していても missing 状態とする
                status: exists ? record.status : TaskStatus.missing,
                diff: exists && countDiff ? diff(for: record) : DiffCounts(),
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt),
                now: now)
        }
    }

    /// Git コマンドを実行せず、台帳由来の更新（status、tool、経過時間等）のみを高速に再適用する。
    /// 差分や worktree 存在確認は前回の集計値を引き継ぐ。
    /// セッション構成（ID 一覧）に変更があった場合は前回の値と整合しないため nil を返す（呼び出し元で完全再集計を行う）。
    public static func reapplied(_ tasks: [CollectedTask], records: [TaskRecord],
                                 now: Int = Int(Date().timeIntervalSince1970))
        -> [CollectedTask]? {
        guard tasks.count == records.count else { return nil }
        var previous: [String: CollectedTask] = [:]
        previous.reserveCapacity(tasks.count)
        for task in tasks { previous[task.id] = task }
        guard previous.count == records.count,
              records.allSatisfy({ previous[$0.id] != nil }) else { return nil }
        return ordered(records).compactMap { record in
            guard let old = previous[record.id] else { return nil }
            return CollectedTask(
                record: record,
                repoName: old.repoName,
                origin: old.origin,
                exists: old.exists,
                status: old.exists ? record.status : TaskStatus.missing,
                diff: old.diff,
                ageSeconds: max(0, now - record.createdAt),
                idleSeconds: max(0, now - record.updatedAt),
                now: now)
        }
    }

    /// 作成日時の降順。同一時刻の場合は元の並び順を維持する（安定ソート）。
    static func ordered(_ records: [TaskRecord]) -> [TaskRecord] {
        records.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 未コミットの変更差分を集計する。
    /// 現在のセッションの作業量を正確に測るため、ベースブランチではなく HEAD からの差分を集計する。
    /// 新規作成ファイルは git diff に含まれないため untracked として別計上し、バイナリファイルも件数として計上する。
    public static func diff(for record: TaskRecord) -> DiffCounts {
        let counted = CountChanges.count(worktree: record.worktree)
        let lines = counted.lines
        // コミットが存在しないリポジトリでは diff HEAD が失敗するため、lines と untracked は独立して処理する。
        return DiffCounts(
            added: lines?.added ?? 0,
            removed: lines?.removed ?? 0,
            untracked: counted.untracked ?? 0,
            binary: lines?.binary ?? 0,
            changedFiles: lines?.files ?? 0)
    }

    /// ユーザーによる確認が必要なタスク（waiting、未確認の done/failed）を抽出する。
    /// TaskStatus.order の優先度順、同一優先度の場合は直近更新順に整列する。
    public static func awaitingReview(_ tasks: [CollectedTask]) -> [CollectedTask] {
        tasks.filter(needsReview).enumerated().sorted { lhs, rhs in
            let (a, b) = (priority(lhs.element), priority(rhs.element))
            if a != b { return a < b }
            if lhs.element.idleSeconds != rhs.element.idleSeconds {
                return lhs.element.idleSeconds < rhs.element.idleSeconds
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 確認が必要なタスクかどうかの判定。通知判定と整合させるため TaskStatus.needsPerson を使用する。
    private static func needsReview(_ task: CollectedTask) -> Bool {
        TaskStatus.needsPerson(status: task.status, seenAt: task.seenAt)
    }

    /// 表示優先順位。TaskStatus.order の定義順と一致させる。
    private static func priority(_ task: CollectedTask) -> Int {
        TaskStatus.order.firstIndex(of: task.attentionStatus) ?? TaskStatus.order.count
    }

    /// エージェントごとの最新レートリミット情報を集約する。
    /// セッションが 0 件の場合でも直近のレートリミットを常時表示できるよう、タスクと台帳キャッシュの両方から集約する。
    /// リセット予定時刻（resetsAt）を経過したウィンドウは、実際の消費状況が未確定なため非表示とする。
    public static func summarizedRateLimits(_ tasks: [CollectedTask],
                                           persisted: [String: AgentRateLimits] = LedgerStore.agentRateLimits(),
                                           now: Int = Int(Date().timeIntervalSince1970)) -> [AgentQuotaSummary] {
        var map: [String: AgentRateLimits] = persisted
        // persisted に無いエージェント（古い台帳からの移行など）のフォールバックとしてタスクから拾う。
        // tasks は新しい順 (createdAt 降順) に並んでいるため、最初に見つかった最新タスクのみを採用する。
        // 過去の完了タスクが最新の persisted や新しいタスクの rateLimits を上書きしないようにする。
        for task in tasks {
            guard let limits = task.rateLimits, !limits.isEmpty else { continue }
            let agentKey = task.resolvedAccountKey
            if map[agentKey] == nil {
                map[agentKey] = limits
            }
        }

        // リセット時刻を過ぎた枠は落とす
        var adjustedMap: [String: AgentRateLimits] = [:]
        for (agentKey, limits) in map {
            let adjusted = AgentRateLimits(fiveHour: live(limits.fiveHour, now: now),
                                           sevenDay: live(limits.sevenDay, now: now))
            if !adjusted.isEmpty {
                adjustedMap[agentKey] = adjusted
            }
        }

        func parseKey(_ key: String) -> (baseAgent: String, account: String?) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                return (parts[0], parts[1])
            }
            return (key, nil)
        }

        // エージェントの決まった順 (AgentKind.order)、次にアカウント名順で安定させる
        return adjustedMap.keys.sorted { lhs, rhs in
            let (baseL, accL) = parseKey(lhs)
            let (baseR, accR) = parseKey(rhs)
            let p1 = AgentKind.order(baseL)
            let p2 = AgentKind.order(baseR)
            if p1 != p2 { return p1 < p2 }
            if baseL != baseR { return baseL < baseR }
            if (accL == nil) != (accR == nil) {
                return accL == nil
            }
            return (accL ?? "") < (accR ?? "")
        }.compactMap { key in
            guard let limits = adjustedMap[key] else { return nil }
            let (baseAgent, account) = parseKey(key)
            return AgentQuotaSummary(key: key, agent: baseAgent, account: account, rateLimits: limits)
        }
    }

    /// まだ有効な枠だけを返す。リセット時刻を過ぎたものは nil (= 出さない)。
    /// resetsAt が無いものは明ける時刻が分からないだけなので、そのまま残す。
    private static func live(_ window: RateLimitWindow?, now: Int) -> RateLimitWindow? {
        guard let window else { return nil }
        if let reset = window.resetsAt, reset <= now { return nil }
        return window
    }
}
