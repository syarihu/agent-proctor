import Foundation

/// アプリから台帳を書くときの通り道。書く側が1つずつ持つ。
///
/// 台帳の書き込みは他のプロセス (hooks) とロックを奪い合うので、**待つ場所を
/// 選ぶ必要がある。** メインスレッドで待てばUIが固まるが、`Task.detached` も
/// 答えにならない。`flock` はスレッドを丸ごと止めるので、コア数ぶんしか
/// スレッドの無い協調プールで待つと他の仕事の前進まで妨げる
/// (同じプロセスには git を起こす数え直しも居る)。
///
/// **走っている最中の依頼は捨てる。** 見張りはタイマーで回っているので、
/// 前の書き込みが詰まっている間にも次の番が来る。積めばロック待ちの列が
/// 伸びる一方だが、どれも「台帳を今の姿に合わせる」仕事なので、
/// 見送っても次のタイマーが拾う。
@MainActor
final class LedgerWriter {
    private static let queue = DispatchQueue(
        label: "net.syarihu.proctor.ledger-write", qos: .utility)

    /// いま流している最中か。メインスレッドからしか触らないので鍵は要らない
    private var inFlight = false

    /// - Parameters:
    ///   - write: 台帳を書く。書き換えたら true を返す。**メイン以外で走る**
    ///   - changed: 書き換えたときにメインスレッドで呼ばれる
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
