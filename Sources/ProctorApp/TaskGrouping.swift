import Foundation
import ProctorKit

/// 一覧のまとめ方。
///
/// Kit に置いていないのは、これが表示の都合だから。CLI の `proctor ls` は
/// 一覧をまとめずに並べるので、この語彙が要るのはサイドバーだけになる。
enum GroupingMode: String, CaseIterable {
    /// リポジトリごと
    case repository
    /// Organization ごと。その下にリポジトリがぶら下がる
    case organization
}

/// リポジトリ1つ分のまとまり。
struct RepoGroup: Identifiable {
    /// 折りたたみを覚えるための鍵。リポジトリ本体の絶対パス
    var id: String
    /// 見出しに出す名前 (パスの末尾)
    var name: String
    var tasks: [CollectedTask]
    /// セッションが乗っていない worktree。畳んだ1行にまとめて出す。
    /// セッションと同じ扱いにはしない。あちらは今動いているもの、
    /// こちらは残っているだけの場所で、急いで見るべきものが違う
    var worktrees: [CollectedWorktree] = []
}

/// Organization 1つ分のまとまり。中にリポジトリがぶら下がる。
struct OrgGroup: Identifiable {
    /// 折りたたみを覚えるための鍵。`org:github.com/syarihu` の形
    var id: String
    /// 見出しに出す名前
    var title: String
    /// アイコンを引く相手。持ち主が分からないまとまりでは nil
    var owner: String?
    /// 持ち主が居るホスト。gh に聞ける相手かの判断に使う
    var host: String?
    var repos: [RepoGroup]

    /// 見出しに出す内訳のもと。畳んだときに中身の状態を数で見せるのに使う
    var tasks: [CollectedTask] { repos.flatMap(\.tasks) }
}

/// 新着 (要確認) 1まとまり分。
///
/// `OrgGroup` と別に持つのは、こちらが**畳めない見出し**だから。中に
/// リポジトリの段を作らず、鍵も覚えるためではなく `ForEach` のためだけに持つ。
struct PendingGroup: Identifiable {
    var id: String
    /// 見出しに出す名前 (持ち主か、リポジトリ名)
    var title: String
    /// アイコンを引く相手。持ち主が読めないまとまりと、
    /// リポジトリでまとめているときは nil
    var owner: String?
    var host: String?
    var tasks: [CollectedTask]
}

/// 一覧を見出しの下にまとめる。
///
/// **動きがあったものを上に置く。** 名前順だと、今まさに動いているプロジェクトが
/// 下に埋もれて気づけない。Organization の並びも、その中のリポジトリの並びも
/// 同じ規則にしてある。片方だけ名前順にすると、上の見出しは動いたのに
/// 中は動かないという、目で追えない並びになる。
enum TaskGrouping {
    /// リポジトリごとにまとめる (これまでの見せ方)
    ///
    /// - Parameter worktrees: セッションが乗っていない worktree。
    ///   これが第2の入り口になる。タスクからだけ組み立てると、
    ///   セッションが1つも無いリポジトリは見出しごと生まれず、
    ///   いちばん放置されている作業場が出てこない
    static func byRepository(_ tasks: [CollectedTask],
                             worktrees: [CollectedRepoWorktrees] = []) -> [RepoGroup] {
        var order: [String] = []
        var box: [String: RepoGroup] = [:]
        for task in tasks {
            if box[task.repo] == nil {
                order.append(task.repo)
                box[task.repo] = RepoGroup(id: task.repo, name: task.repoName, tasks: [])
            }
            box[task.repo]?.tasks.append(task)
        }
        attach(worktrees, order: &order, box: &box)
        return stable(order.compactMap { box[$0] }) { recency($0.tasks) }
    }

    /// 残っている worktree を、対応するリポジトリのまとまりに足す。
    /// まとまりがまだ無ければ (セッションが1つも無いリポジトリ) ここで作る。
    ///
    /// **何も残っていないリポジトリの見出しは作らない。** 中身の無い見出しが
    /// 並ぶと、一覧の意味が「今どうなっているか」から「どこを触ったか」に
    /// すり替わってしまう
    private static func attach(_ worktrees: [CollectedRepoWorktrees],
                               order: inout [String],
                               box: inout [String: RepoGroup]) {
        for group in worktrees {
            let idle = group.idle
            if box[group.repo] == nil {
                guard !idle.isEmpty else { continue }
                order.append(group.repo)
                box[group.repo] = RepoGroup(id: group.repo, name: group.repoName, tasks: [])
            }
            box[group.repo]?.worktrees = idle
        }
    }

    /// Organization ごとにまとめ、その下にリポジトリをぶら下げる。
    ///
    /// 持ち主が読めなかったリポジトリは1つのまとまりに寄せる。**中に混ぜて
    /// しまうと、無関係なリポジトリが誰かの組織の下に並ぶ。** 別立てにすれば、
    /// remote が付いていないだけだと分かる。
    ///
    /// - Parameter unknownTitle: 持ち主が読めないまとまりの見出し
    static func byOrganization(_ tasks: [CollectedTask],
                               worktrees: [CollectedRepoWorktrees] = [],
                               unknownTitle: String) -> [OrgGroup] {
        var order: [String] = []
        var box: [String: OrgGroup] = [:]
        // リポジトリ単位のまとまりは1か所で作る。持ち主で束ね直すのはそのあと。
        // 2通りに書くと、worktree が片方にしか出ないという食い違いが生まれる
        let repos = byRepository(tasks, worktrees: worktrees)
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

    /// 持ち主から、まとまりの見出しに要るものを作る。
    ///
    /// **1か所で作る。** Organization の見出しと新着のまとめの2通りに書くと、
    /// 鍵や名前の決め方がずれて、同じ持ち主が別のまとまりに見える。
    ///
    /// - Parameter unknownTitle: 持ち主が読めないまとまりの見出し
    private static func heading(for origin: RepoOrigin?, unknownTitle: String)
        -> (id: String, title: String, owner: String?, host: String?) {
        guard let origin else { return (unknownKey, unknownTitle, nil, nil) }
        // アイコンを引けるのは GitHub だけ。それ以外のホストは名前で並べて、
        // 代わりの絵を描かせる。
        //
        // **鍵は小文字に寄せる。** これは見出しに出す名前 (title) と違って、
        // 覚えておく先とファイル名になる。原文のままにすると、先に現れた
        // タスクの表記次第で Syarihu と syarihu を行き来し、大小を区別する
        // ボリュームでは同じ人のアイコンが2枚落ちる
        return ("org:" + origin.groupKey, origin.owner,
                origin.isGitHub ? origin.owner.lowercased() : nil, origin.host)
    }

    /// 新着 (要確認) を見出しの下にまとめる。
    ///
    /// **渡された順を崩さない。** 一覧のまとめ (`byRepository` / `byOrganization`) と
    /// 分けているのはそのためで、あちらは動きの新しい順に並べ替える。
    /// ここに来るのは急ぎの順 (`CollectTasks.awaitingReview`) に並んだものなので、
    /// 並べ直すといちばん待たせているものが上から落ちる。
    ///
    /// 見出しの順も**中で最初に現れたものが先**。つまり急いでいるまとまりが上に来る。
    ///
    /// **まとめるほうを優先している。** 同じ持ち主のものを1か所に寄せるので、
    /// 全体を通した急ぎの順とは一致しない (先頭の持ち主の「完了」が、
    /// 次の持ち主の「確認待ち」より上に出ることがある)。まとまりを崩して
    /// 厳密な順に並べると、同じ見出しが何度も現れて「どこが待っているか」が
    /// 一目で分からなくなる。急ぐものから見たい向きは、まとまりの順のほうが担う
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
                // リポジトリでまとめているときはアイコンを出さない。
                // 持ち主を読まないまとめ方なので、そこだけ組織の絵が出ると、
                // 見出しが何を指しているのか分からなくなる
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

    /// 経過の短い順。**同じ値のときは元の並びを保つ。**
    ///
    /// 2つが同時に走っていれば経過はどちらも 0 になるので、並びが引き分けるのは
    /// 日常的に起きる。Swift の `sorted` は安定ではないため、引き分けたときに
    /// 見出しが入れ替わりうる。**動いていないものが動いて見えるのがいちばん困る**
    /// ので、添字で決着をつける (`CollectTasks.ordered` と同じ考え方)
    private static func stable<T>(_ items: [T], by key: (T) -> Int) -> [T] {
        items.enumerated().sorted { lhs, rhs in
            let (a, b) = (key(lhs.element), key(rhs.element))
            if a != b { return a < b }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 持ち主が読めなかったものを寄せる先。**"org:" を付けないのは、
    /// 実在する組織の鍵とぶつからないようにするため** (GitHub に "unknown" という
    /// 組織があっても、こちらは "github.com/unknown" になるので別物ではあるが、
    /// 種類そのものを分けておくほうが取り違えの余地が無い)
    private static let unknownKey = "no-organization"

    private static func recency(_ tasks: [CollectedTask]) -> Int {
        tasks.map(\.idleSeconds).min() ?? .max
    }
}
