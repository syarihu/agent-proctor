import Foundation
import Model
import RepositoryGit
import RepositoryLedger

/// 直近作業を行ったリポジトリの一覧を抽出する。
/// セッション終了直後でもアクセス経路を維持できるよう、直近（既定で7日間）使われたリポジトリを保持する。
/// git コマンドは呼び出さず、台帳の情報のみを参照する。
public enum CollectRecentRepos {
    /// 保持期間（秒）。直近7日間。
    public static let window = 7 * 24 * 3600

    /// - Parameters:
    ///   - repos: 台帳に記録されているリポジトリと最終参照時刻の辞書。nil の場合は内部で取得する
    ///   - within: 直近とみなす有効期間（秒）
    ///   - now: 現在時刻（テスト用に差し替え可能）
    /// - Returns: 一覧に保持するリポジトリパスの集合
    ///
    /// ディレクトリの実在チェックは CollectWorktrees 側で行われるためここでは行わない。
    /// 台帳の最終参照時刻は書き込み頻度抑制のため24時間ごとに更新されるため、期間境界は最大1日の誤差があり得る。
    /// 古いリポジトリの台帳からの削除は行わず、表示上のフィルタリングのみを行う（放置された worktree の検出漏れを防ぐため）。
    public static func collect(repos: [String: Int]? = nil,
                               within: Int = window,
                               now: Int = Int(Date().timeIntervalSince1970)) -> Set<String> {
        let lastSeen = repos ?? LedgerStore.repos()
        return Set(lastSeen.filter { _, seen in
            // 時刻が未記録のものは除外。時刻巻き戻り（now < seen）は安全側に倒して保持対象とする。
            seen > 0 && now - seen <= within
        }.keys)
    }
}
