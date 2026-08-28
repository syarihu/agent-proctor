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
    private var currentDirectory: String?
    /// 前に配ったタブ番号。同じものを配り直さないために覚えておく
    /// (@Published は同じ値でも一覧をまるごと組み直させる)
    private var tabNumbers: [String: Int] = [:]
    private let writer = LedgerWriter()

    /// - Parameters:
    ///   - onFocus: 見ているタブが変わったときに呼ばれる
    ///   - onDirectory: 見ているタブの現在地が変わったときに呼ばれる。
    ///     **エージェントが動いていない場所も知りたい**ので、台帳とは別に追う
    ///   - onTabNumbers: タブ番号 (⌘N の N) の顔ぶれが変わったときに呼ばれる。
    ///     鍵はセッションの guid
    ///   - onSeen: 台帳に確認済みを書いたときに呼ばれる
    init(onFocus: @escaping (String?) -> Void,
         onDirectory: @escaping (String?) -> Void,
         onTabNumbers: @escaping ([String: Int]) -> Void,
         onSeen: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // **裏に回っている間は何も聞かない。** 問い合わせは Apple Event の
                // 往復で、相手が忙しいとこちらのメインスレッドごと待たされる。
                // タブが切り替わるのは前面のときだけなので、聞くだけ無駄になる。
                //
                // 印を付けるほうも同じ扱いでよい。裏で終わった分まで「見た」ことに
                // すると、気づかないうちに既読になってしまう
                guard ItermBridge.isItermFrontmost else { return }

                // 聞けなかったとき (nil) は前の値を保つ。iTerm2 が一瞬答えなかった
                // だけで印が飛ぶと、行がちらついて落ち着かない
                if let tab = ItermBridge.focusedTab() {
                    let resolved = tab.session.isEmpty ? nil : tab.session
                    if resolved != self.current {
                        self.current = resolved
                        onFocus(resolved)
                    }
                    // 現在地が読めないタブ (ssh 越しなど) では前の値を保つ。
                    // 「どこにも居ない」と受け取ると、そのリポジトリの worktree が
                    // 一覧から落ちてしまう
                    if !tab.directory.isEmpty, tab.directory != self.currentDirectory {
                        self.currentDirectory = tab.directory
                        onDirectory(tab.directory)
                    }
                    // **番号は空でも配る。** 窓を全部閉じたときの空は
                    // 「タブが1つも無い」という答えなので、古い番号を残すと
                    // もう無いタブへ ⌘N を押させることになる。
                    // 聞けなかったとき (nil) はここへ来ないので取り違えない
                    if tab.tabNumbers != self.tabNumbers {
                        self.tabNumbers = tab.tabNumbers
                        onTabNumbers(tab.tabNumbers)
                    }
                }
                // 台帳を書くのはメインスレッドから外す (理由は LedgerWriter)
                let session = self.current
                self.writer.submit({ (try? MarkSessionSeen.run(itermSession: session)) == true },
                                   changed: onSeen)
            }
        }
    }

    deinit { timer?.invalidate() }
}
