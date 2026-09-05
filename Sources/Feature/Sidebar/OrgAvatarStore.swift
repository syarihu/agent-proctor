import AppKit
import Combine
import UseCaseTask

/// Organization アイコンの取得・メモリキャッシュを担当するストア。
///
/// View からの直接のファイルアクセスや重複フェッチを防ぎ、
/// バックグラウンドでの非同期取得と取得完了時の `@Published` による再描画制御を提供する。
/// キャッシュの永続化および更新間隔は FetchOrganizationAvatar に委譲する。
@MainActor
public final class OrgAvatarStore: ObservableObject {
    @Published public private(set) var images: [String: NSImage] = [:]

    public init() {}

    /// 現在取得処理を実行中のオーナー名集合（重複フェッチの抑止用）
    private var loading: Set<String> = []

    /// 取得失敗時の最大試行回数（初回含む。存在しない組織への無限リクエストを防止）
    private static let maxAttempts = 3
    /// リトライ間隔（FetchOrganizationAvatar のキャッシュクールダウン10分を超えるよう設定）
    private static let retryDelay: Duration = .seconds(11 * 60)

    /// - Parameters:
    ///   - owner: GitHub オーナー名（login）
    ///   - host: ホスト名（GitHub 以外は FetchOrganizationAvatar 側で除外）
    func load(owner: String, host: String) async {
        guard images[owner] == nil, !loading.contains(owner) else { return }
        loading.insert(owner)
        defer { loading.remove(owner) }

        for attempt in 1...Self.maxAttempts {
            if await attemptLoad(owner: owner, host: host) { return }
            guard attempt < Self.maxAttempts else { return }
            // ビューの破棄（.task のキャンセル）を検知して待機を中断
            do { try await Task.sleep(for: Self.retryDelay) } catch { return }
        }
    }

    /// - Returns: 画像の取得・デコードに成功した場合は true
    private func attemptLoad(owner: String, host: String) async -> Bool {
        // I/O およびネットワーク処理をメインスレッド外で実行。NSImage のスレッド間受け渡しを避けるためパスのみ取得
        let file = await Task.detached(priority: .utility) {
            FetchOrganizationAvatar.fetch(owner: owner, host: host)
        }.value
        guard let file else { return false }
        guard let image = NSImage(contentsOf: file) else {
            // 画像ファイルが破損している場合はキャッシュを破棄して次回再取得を可能にする
            FetchOrganizationAvatar.discard(owner: owner)
            return false
        }
        images[owner] = image
        return true
    }
}
