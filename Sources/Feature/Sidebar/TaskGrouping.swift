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
    /// リポジトリの持ち主（remote から読んだもの）。引けなければ nil
    var origin: RepoOrigin? = nil
    var tasks: [CollectedTask]
    /// セッションが存在しない待機中 worktree 一覧
    var worktrees: [CollectedWorktree] = []

    /// `owner/repo` の見出し。
    ///
    /// 段を1つに畳むときに使う。持ち主の段が無くなるぶん、リポジトリ名だけだと
    /// 別の持ち主の同名リポジトリと見分けが付かなくなる
    var qualifiedName: String { TaskGrouping.qualified(origin, fallback: name) }

    /// アバター取得用オーナー名（GitHub 以外や特定不能時は nil）
    var avatarOwner: String? {
        guard let origin, origin.isGitHub else { return nil }
        return origin.owner.lowercased()
    }

    var host: String? { origin?.host }
}

/// 状態単位のグループ。配下にリポジトリの小見出しを持つ。
///
/// リポジトリで切ると、いま手を動かしているセッションが各リポジトリに散る。
/// 「どれが動いているか」を先に見せたいので、外側を状態にして中をリポジトリで分ける
struct StatusGroup: Identifiable {
    /// 折りたたみ状態永続化用キー（`status:waiting` 形式）
    var id: String
    /// 見出し表示名
    var title: String
    /// 件数バッジの色に使う代表状態
    var status: String
    /// 人の手が要る箱かどうか。要確認ストリップと同じ行を出すかの判定に使う
    var needsPerson: Bool
    var repos: [RepoGroup]

    /// 配下全リポジトリのタスク一覧
    var tasks: [CollectedTask] { repos.flatMap(\.tasks) }
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
            // 持ち主はタスクごとに欠けることがあるので、引けたものを採る
            if let origin = task.origin { box[task.repo]?.origin = origin }
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
            // セッションが1つも無いリポジトリはタスクから持ち主を引けない
            if box[group.repo]?.origin == nil { box[group.repo]?.origin = group.origin }
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
        for repo in repos {
            // 持ち主はタスク側にも worktree 側にも付いており、byRepository が
            // 拾い終えている。ここで引き直すと2通りの拾い方が並ぶ
            let head = heading(for: repo.origin, unknownTitle: unknownTitle)
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

    /// 状態単位でグループ化する。
    ///
    /// セッションの乗っていない worktree は出さない。状態を持たないので入る箱が無く、
    /// 入れると「過去のリポジトリが下に溜まる」のをそのまま持ち込むことになる
    ///
    /// - Returns: 要確認・実行中・それ以外の順。中身が無い箱は省く
    static func byStatus(_ tasks: [CollectedTask]) -> [StatusGroup] {
        var box: [String: [CollectedTask]] = [:]
        for task in tasks { box[bucket(for: task), default: []].append(task) }
        return buckets.compactMap { bucket in
            guard let inside = box[bucket.key], !inside.isEmpty else { return nil }
            return StatusGroup(id: "status:" + bucket.key,
                               title: Localized.text(bucket.titleKey),
                               status: bucket.status,
                               needsPerson: bucket.key == waitingBucket,
                               repos: byRepository(inside))
        }
    }

    /// 箱の鍵。
    ///
    /// `StatusGroup.id` を通して `GroupFolding` の永続キーになるので、値は変えないこと。
    /// `TaskStatus` の定数を流用していないのは、箱とタスクの状態が別の語彙だから。
    /// done の箱は確認済み・idle・missing をまとめて受ける器で、状態の done とは範囲が違う
    private static let waitingBucket = "waiting"
    private static let runningBucket = "running"
    private static let doneBucket = "done"

    /// 状態の箱。出す順もこの並びで決める
    private static let buckets: [(key: String, titleKey: String, status: String)] = [
        (waitingBucket, "app.group.status.waiting", TaskStatus.waiting),
        (runningBucket, "app.group.status.running", TaskStatus.running),
        (doneBucket, "app.group.status.done", TaskStatus.seen),
    ]

    /// どの箱に入れるか。
    ///
    /// 要確認の判定は `TaskStatus.needsPerson` をそのまま使う。ここに独自の条件を書くと、
    /// 上の要確認ストリップと下の一覧で「人の手が要る」の意味が食い違う
    private static func bucket(for task: CollectedTask) -> String {
        if TaskStatus.needsPerson(status: task.status, seenAt: task.seenAt) { return waitingBucket }
        if task.status == TaskStatus.running { return runningBucket }
        return doneBucket
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
            case .status:
                // 状態で切っているときストリップは出さない (要確認の箱が兼ねる) ので
                // ここは通らない。switch を網羅させるために、箱の中と同じ形にしておく
                let owner = heading(for: task.origin, unknownTitle: unknownTitle)
                head = (task.repo, qualified(task.origin, fallback: task.repoName),
                        owner.owner, owner.host)
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

    /// `owner/repo` の見出し。持ち主が引けなければ渡された名前のまま
    static func qualified(_ origin: RepoOrigin?, fallback: String) -> String {
        guard let origin else { return fallback }
        return "\(origin.owner)/\(origin.name)"
    }

    /// オーナー特定不能グループ用キー（実在する組織キーとの衝突を防ぐため接頭辞なしの固定値）
    private static let unknownKey = "no-organization"

    private static func recency(_ tasks: [CollectedTask]) -> Int {
        tasks.map(\.idleSeconds).min() ?? .max
    }
}
