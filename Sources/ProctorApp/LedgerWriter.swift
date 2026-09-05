import Foundation

/// アプリ側からの台帳書き込みを直列化するユーティリティ。
/// flock による UI ブロックおよび Swift Concurrency 協調スレッドプールの枯渇を防ぐため、専用のシリアル DispatchQueue で実行する。
/// 実行中の重複リクエストは破棄し、ロック待ちキューの肥大化を防ぐ。
@MainActor
final class LedgerWriter {
    private static let queue = DispatchQueue(
        label: "net.syarihu.proctor.ledger-write", qos: .utility)

    /// 処理実行中フラグ（MainActor で管理）
    private var inFlight = false

    /// - Parameters:
    ///   - write: 台帳書き込み処理。変更があった場合は true を返す（専用キュー上で実行される）
    ///   - changed: 書き換え完了時にメインスレッドで呼ばれるコールバック
    func submit(_ write: @escaping @Sendable () -> Bool,
                changed: @escaping @MainActor () -> Void) {
        guard !inFlight else { return }
        inFlight = true
        LedgerWriter.queue.async {
            let didChange = write()
            Task { @MainActor in
                self.inFlight = false
                if didChange { changed() }
            }
        }
    }
}
