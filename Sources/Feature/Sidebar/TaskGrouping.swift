import Foundation
import DesignSystem
import Model
import Resources
import UseCaseTask

/// リポジトリ単位のグループ。
struct RepoGroup: Identifiable {
    /// 折りたたみ状態永続化用キー（リポジトリの絶対パス）
    var id: String
    /// 見出し表示名（リポジトリ名）
    var name: String
    var tasks: [CollectedTask]
    /// セッションが存在しない待機中 worktree 一覧
    var worktrees: [CollectedWorktree] = []
}

/// Organization 単位のグループ。配下にリポジトリグループを保持する。
struct OrgGroup: Identifiable {
    /// 折りたたみ状態永続化用キー（`org:github.com/syarihu` 形式）
    var id: String
    /// 見出し表示名
    var title: String
    /// アバター取得用オーナー名（特定不能な場合は nil）
    var owner: String?
    /// ホスト名（GitHub API 呼び出し可否判定用）
    var host: String?
    var repos: [RepoGroup]

    /// 配下全リポジトリのタスク一覧（折りたたみ時のステータス集計用）
    var tasks: [CollectedTask] { repos.flatMap(\.tasks) }
}

/// 未確認セッション（要対応）のグループ。
///
/// 折りたたみ不可とし、リポジトリ階層を持たせずフラットに表示する。
struct PendingGroup: Identifiable {
    var id: String
    /// 見出し表示名（オーナー名またはリポジトリ名）
    var title: String
    /// アバター取得用オーナー名（リポジトリ別グループ時やオーナー特定不能時は nil）
    var owner: String?
    var host: String?
    var tasks: [CollectedTask]
}

/// セッション一覧のグループ化ロジック。
/// 直近に更新・稼働があった項目を上位に配置する安定ソートを提供する。
enum TaskGrouping {
    /// リポジトリ単位でグループ化する。
    ///
    /// - Parameters:
    ///   - tasks: 集計対象タスク一覧
    ///   - worktrees: セッションの存在しない worktree 一覧（タスクのないリポジトリも可視化対象とする）
    ///   - keeping: タスクや worktree が存在しなくても一覧に維持するリポジトリパスの集合（直近アクセスリポジトリ）
    /// - Returns: 直近稼働順にソートされたリポジトリグループ一覧
    static func byRepository(_ tasks: [CollectedTask],
                             worktrees: [CollectedRepoWorktrees] = [],
                             keeping: Set<String> = []) -> [RepoGroup] {
        var order: [String] = []
        var box: [String: RepoGroup] = [:]
        for task in tasks {
            if box[task.repo] == nil {
                order.append(task.repo)
                box[task.repo] = RepoGroup(id: task.repo, name: task.repoName, tasks: [])
            }
            box[task.repo]?.tasks.append(task)
        }
        attach(worktrees, keeping: keeping, order: &order, box: &box)
        return stable(order.compactMap { box[$0] }) { recency($0.tasks) }
    }

    /// セッションのないリポジトリが worktree 単体で見出しを維持できるかを判定する
    private static func standsAlone(_ group: CollectedRepoWorktrees) -> Bool {
        !group.idle.isEmpty
    }

    /// 待機中 worktree を対応するリポジトリグループに紐付ける。
    /// グループが存在しない場合、worktree が存在するか直近リポジトリに含まれる場合のみ新規作成する
    /// （過去に触っただけの無関係なリポジトリで見出しが増殖するのを防ぐ）。
    private static func attach(_ worktrees: [CollectedRepoWorktrees],
                               keeping: Set<String>,
                               order: inout [String],
                               box: inout [String: RepoGroup]) {
        for group in worktrees {
            if box[group.repo] == nil {
                guard standsAlone(group) || keeping.contains(group.repo) else { continue }
                order.append(group.repo)
                box[group.repo] = RepoGroup(id: group.repo, name: group.repoName, tasks: [])
            }
            box[group.repo]?.worktrees = group.idle
        }
    }

    /// Organization 単位でグループ化し、配下にリポジトリグループを配置する。
    ///
    /// オーナーが特定できないリポジトリは独立した未分類グループに集約し、
    /// 既存の組織グループへの誤混入を防ぐ。
    ///
    /// - Parameters:
    ///   - tasks: 集計対象タスク一覧
    ///   - worktrees: セッションの存在しない worktree 一覧
    ///   - keeping: 維持対象リポジトリ集合
    ///   - unknownTitle: オーナー特定不能グループの表示見出し
    static func byOrganization(_ tasks: [CollectedTask],
                               worktrees: [CollectedRepoWorktrees] = [],
                               keeping: Set<String> = [],
                               unknownTitle: String) -> [OrgGroup] {
        var order: [String] = []
        var box: [String: OrgGroup] = [:]
        // リポジトリ単位のまとまりは1か所で作る。持ち主で束ね直すのはそのあと。
        // 2通りに書くと、worktree が片方にしか出ないという食い違いが生まれる
        let repos = byRepository(tasks, worktrees: worktrees, keeping: keeping)
        // 持ち主はタスク側にも worktree 側にも付いている。セッションが1つも
        // 無いリポジトリではタスクから引けないので、worktree のほうから拾う
        var origins: [String: RepoOrigin] = [:]
        for task in tasks { origins[task.repo] = task.origin ?? origins[task.repo] }
        for group in worktrees { origins[group.repo] = origins[group.repo] ?? group.origin }

        for repo in repos {
            let head = heading(for: origins[repo.id], unknownTitle: unknownTitle)
            if box[head.id] == nil {
                order.append(head.id)
                box[head.id] = OrgGroup(id: head.id, title: head.title,
                                        owner: head.owner, host: head.host, repos: [])
            }
            box[head.id]?.repos.append(repo)
        }
        let groups = order.compactMap { box[$0] }.map { org -> OrgGroup in
            var sorted = org
            sorted.repos = stable(sorted.repos) { recency($0.tasks) }
            return sorted
        }
        return stable(groups) { recency($0.tasks) }
    }

    /// リポジトリの origin 情報からグループ用の見出し情報を生成する。
    ///
    /// - Parameter unknownTitle: オーナー特定不能時の見出し
    private static func heading(for origin: RepoOrigin?, unknownTitle: String)
        -> (id: String, title: String, owner: String?, host: String?) {
        guard let origin else { return (unknownKey, unknownTitle, nil, nil) }
        // アバター取得は GitHub のみ対応。キーは大文字小文字の違いによるキャッシュ重複やファイル名揺れを防ぐため小文字に正規化する
        return ("org:" + origin.groupKey, origin.owner,
                origin.isGitHub ? origin.owner.lowercased() : nil, origin.host)
    }

    /// 未確認セッション（要対応）をグループ化する。
    ///
    /// 優先度順（CollectTasks.awaitingReview）を維持するため再ソートは行わず、
    /// 出現順に基づいてグループを整列する。
    static func pending(_ tasks: [CollectedTask], by mode: GroupingMode,
                        unknownTitle: String) -> [PendingGroup] {
        var order: [String] = []
        var box: [String: PendingGroup] = [:]
        for task in tasks {
            let head: (id: String, title: String, owner: String?, host: String?)
            switch mode {
            case .organization:
                head = heading(for: task.origin, unknownTitle: unknownTitle)
            case .repository:
                // リポジトリ単位グループ化時はアバターを表示しない
                head = (task.repo, task.repoName, nil, nil)
            }
            if box[head.id] == nil {
                order.append(head.id)
                box[head.id] = PendingGroup(id: head.id, title: head.title,
                                            owner: head.owner, host: head.host, tasks: [])
            }
            box[head.id]?.tasks.append(task)
        }
        return order.compactMap { box[$0] }
    }

    /// 経過時間の昇順ソート。同値時は元のインデックス順を維持する安定ソート（画面上の不要な並び順チラつきを防止）。
    private static func stable<T>(_ items: [T], by key: (T) -> Int) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let (a, b) = (key(lhs.element), key(rhs.element))
            if a != b { return a < b }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// オーナー特定不能グループ用キー（実在する組織キーとの衝突を防ぐため接頭辞なしの固定値）
    private static let unknownKey = "no-organization"

    private static func recency(_ tasks: [CollectedTask]) -> Int {
        tasks.map(\.idleSeconds).min() ?? .max
    }
}
