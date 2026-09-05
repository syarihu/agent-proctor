import Combine
import Foundation
import Model
import UseCaseTask

/// 各 worktree に対応する GitHub Pull Request 参照の取得・保持を担当するストア。
///
/// View の再描画ごとの不要な gh コマンド実行を防ぎ、同時実行数制御（直列化・上限管理）
/// および可視状態に応じたフェッチ制御を行う。
/// キャッシュ有効期限や再フェッチ間隔のロジックは ResolvePullRequest に委譲する。
@MainActor
public final class PullRequestStore: ObservableObject {
    /// worktree ごとの PR 参照情報
    @Published public private(set) var refs: [String: PullRequestRef] = [:]

    public init() {}

    /// 現在取得処理を実行中の worktree パス集合（重複フェッチの抑止用）
    private var loading: Set<String> = []

    /// 取得実行中に要求された強制再取得リクエスト（gh pr create 直後など、取得完了後の再フェッチ用）
    private var pendingForced: Set<String> = []

    /// サイドバーが表示されているかどうかのフラグ（非表示時のバックグラウンド実行を抑制）
    private var enabled = false

    /// 現在表示対象となっている worktree パス集合（初期化前の全破棄を防ぐため初期値は nil）
    private var active: Set<String>?

    /// ターン終了時の強制取得を試行中の worktree パス集合（重複タスクの生成を抑制）
    private var forcing: Set<String> = []

    /// 定期ポーリング間隔（キャッシュ期限切れ検知用）
    private static let tick: Duration = .seconds(30)
    /// 同時実行枠が埋まっていた場合のリトライ待機時間
    private static let busyRetry: Duration = .seconds(2)
    /// gh プロセスの同時実行上限数（システム負荷およびタイムアウト多発の抑制）
    private static let maxConcurrent = 4
    /// 強制再取得時の最大リトライ試行回数（先行フェッチの最大実行時間約17秒をカバーする回数）
    private static let forcedAttempts = 12

    /// サイドバーの表示状態の変更通知
    public func setEnabled(_ on: Bool) { enabled = on }

    /// 指定された worktree の PR 情報を定期的に監視・取得する。
    /// SwiftUI の .task 修飾子から呼び出され、ビューの破棄に伴い自動的にキャンセルされる。
    func watch(worktree: String, origin: RepoOrigin?) async {
        while !Task.isCancelled {
            let ran = await load(worktree: worktree, origin: origin, forced: false)
            // 同時実行枠制限により見送った場合は、初回表示遅延を防ぐため短いリトライ間隔を使用する
            do { try await Task.sleep(for: ran ? Self.tick : Self.busyRetry) } catch { return }
        }
    }

    /// エージェントのターン終了時（`gh pr create` 等の完了直後）に呼び出し、未作成キャッシュを破棄して即座に再取得を試みる
    func noteTurnEnded(worktree: String, origin: RepoOrigin?) {
        ResolvePullRequest.forgetAbsent(worktree: worktree)
        guard !forcing.contains(worktree) else { return }
        forcing.insert(worktree)
        Task {
            defer { forcing.remove(worktree) }
            // 実行枠が埋まっている場合でも即時反映を優先するためリトライを繰り返す
            for _ in 0..<Self.forcedAttempts {
                if await load(worktree: worktree, origin: origin, forced: true) { return }
                do { try await Task.sleep(for: Self.busyRetry) } catch { return }
            }
        }
    }

    /// 一覧から除外された worktree の古いキャッシュを破棄する
    public func keep(worktrees: Set<String>) {
        active = worktrees
        let stale = refs.keys.filter { !worktrees.contains($0) }
        guard !stale.isEmpty else { return }
        for key in stale { refs.removeValue(forKey: key) }
    }

    /// - Returns: 取得処理を実行した場合は true、同時実行数制限等で見送った場合は false
    @discardableResult
    private func load(worktree: String, origin: RepoOrigin?, forced: Bool) async -> Bool {
        // サイドバー非表示時は取得を行わない（通常間隔で待機）
        guard enabled else { return true }
        // 表示対象外となった worktree は処理をスキップ。
        // 未反映の新規行の可能性を考慮し、active に未登録の場合は短いリトライ間隔を促すため false を返す
        guard active?.contains(worktree) != false else { return false }
        if loading.contains(worktree) {
            if forced { pendingForced.insert(worktree) }
            return true
        }
        guard loading.count < Self.maxConcurrent else { return false }

        loading.insert(worktree)
        // I/O および外部コマンド実行のためメインスレッドから分離して実行
        let found = await Task.detached(priority: .utility) {
            ResolvePullRequest.resolve(worktree: worktree, origin: origin)
        }.value
        loading.remove(worktree)
        apply(found, for: worktree)

        // 取得中に届いた再取得要求を処理
        if pendingForced.remove(worktree) != nil {
            ResolvePullRequest.forgetAbsent(worktree: worktree)
            await load(worktree: worktree, origin: origin, forced: false)
        }
        return true
    }

    private func apply(_ found: PullRequestRef?, for worktree: String) {
        // 非同期処理完了時に既に対象外となっている worktree の復元を防止
        guard active?.contains(worktree) != false else { return }
        guard refs[worktree] != found else { return }
        // PR が存在しない、またはクローズ等で消失した場合は辞書からエントリを削除する
        if let found {
            refs[worktree] = found
        } else {
            refs.removeValue(forKey: worktree)
        }
    }
}
