import AppKit
import AppState
import DesignSystem
import Foundation
import Model

/// 俯瞰に出す島を台帳タスクから構築する共通ビルダー。
///
/// サイドバーの俯瞰モードと独立したオフィス窓の両方から呼ばれ、同じ台帳から同じ並びの島を生成する。
@MainActor
public enum DeskIslands {
    /// 台帳タスクと状態から島の一覧を生成する。
    /// 並び順は一覧と揃える（store.tasks の順）。
    public static func build(
        tasks: [CollectedTask],
        focusedSession: String?,
        showTabNumbers: Bool,
        tabNumbers: [String: Int]
    ) -> [DeskIsland] {
        var order: [String] = []
        var byRepo: [String: [DeskSeat]] = [:]
        for task in tasks {
            if byRepo[task.repo] == nil {
                byRepo[task.repo] = []
                order.append(task.repo)
            }
            let isCurrent: Bool = {
                guard let focused = focusedSession, !focused.isEmpty else { return false }
                return task.itermSession == focused
            }()
            let tabNum: Int? = {
                guard showTabNumbers else { return nil }
                guard let session = task.itermSession, !session.isEmpty else { return nil }
                return tabNumbers[session]
            }()
            byRepo[task.repo]?.append(
                DeskSeat(id: task.id,
                         name: task.displayName,
                         status: task.displayStatus,
                         needsPerson: TaskStatus.needsPerson(status: task.status,
                                                             seenAt: task.seenAt),
                         contextPercent: task.contextPercent,
                         subagents: task.subagents,
                         helpers: task.currentSubagents.map {
                             DeskHelper(id: $0.id, name: $0.name, activity: $0.activity)
                         },
                         activity: task.currentActivity,
                         isCurrent: isCurrent,
                         tabNumber: tabNum,
                         model: task.model,
                         agent: task.agentDisplayName))
        }
        return order.map { repo in
            DeskIsland(repo: tasks.first { $0.repo == repo }?.repoName ?? repo,
                       seats: byRepo[repo] ?? [])
        }
    }

    /// TaskStore と Appearance から島の一覧を生成するコンビニエンスメソッド。
    public static func build(store: TaskStore, appearance: Appearance) -> [DeskIsland] {
        build(tasks: store.tasks,
              focusedSession: store.focusedSession,
              showTabNumbers: appearance.showTabNumbers,
              tabNumbers: store.tabNumbers)
    }
}
