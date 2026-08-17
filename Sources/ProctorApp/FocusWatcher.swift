import Foundation
import ProctorKit

/// いま見ている iTerm2 のタブを追いかける。
///
/// 使い道は2つ。
///   - 一覧のどの行が「いま開いているタブ」かの印
///   - 終わったものを見たときに、確認済みの印を付ける (MarkSessionSeen)
///
/// iTerm2 に同梱の Python からなら FocusMonitor が変化を押してくれるが、
/// アプリからは聞きに行くしかないので定期的に叩く。1回あたり Apple Event の
/// 往復1つで済むよう、AppleScript 側で現在のセッションだけを取っている。
///
/// **どのタブを見ているかは iTerm2 が前面かどうかとは別に持つ。**
/// サイドバーを操作している間は iTerm2 が前面から外れるので、そこで消すと
/// 押した瞬間に居場所の印が消えてしまう。裏に回っていても
/// 「さっきまで見ていたタブ」を指したままのほうが分かりやすい。
@MainActor
final class FocusWatcher {
    /// タブの切り替えについていければいいので、そこまで細かくは要らない
    private let interval: TimeInterval = 1.0
    private var timer: Timer?
    private var current: String?

    /// - Parameters:
    ///   - onFocus: 見ているタブが変わったときに呼ばれる
    ///   - onSeen: 台帳に確認済みを書いたときに呼ばれる
    init(onFocus: @escaping (String?) -> Void, onSeen: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // 聞けなかったとき (nil) は前の値を保つ。iTerm2 が一瞬答えなかった
                // だけで印が飛ぶと、行がちらついて落ち着かない
                if let session = ItermBridge.focusedSession() {
                    let resolved = session.isEmpty ? nil : session
                    if resolved != self.current {
                        self.current = resolved
                        onFocus(resolved)
                    }
                }
                // 印を付けるのは前面のときだけ。裏に回っている間に終わった分まで
                // 「見た」ことにすると、気づかないうちに既読になってしまう
                guard ItermBridge.isItermFrontmost else { return }
                if (try? MarkSessionSeen.run(itermSession: self.current)) == true {
                    onSeen()
                }
            }
        }
    }

    deinit { timer?.invalidate() }
}
