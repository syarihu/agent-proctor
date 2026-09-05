import Foundation
import ItermBridge
import UseCaseSession

/// iTerm2 のアクティブタブとディレクトリを定期監視するウォッチャー。
/// 現在選択中のタブの特定および、閲覧済みタスクへの確認済み（seen）反映を行う。
/// サイドバー操作時に選択インジケータが消失するのを防ぐため、iTerm2 の前面状態とは独立して最後に選択されていたタブ情報を保持する。
@MainActor
final class FocusWatcher {
    /// ポーリング間隔
    private let interval: TimeInterval = 1.0
    private var timer: Timer?
    private var current: String?
    private var currentDirectory: String?
    /// 前回通知済みのタブ番号マッピング（重複通知による不要な View 再構築を回避）
    private var tabNumbers: [String: Int] = [:]
    private let writer = LedgerWriter()

    /// - Parameters:
    ///   - onFocus: フォーカス中タブ変更時のコールバック
    ///   - onDirectory: カレントディレクトリ変更時のコールバック（エージェント非稼働のディレクトリも含む）
    ///   - wantsTabNumbers: タブ番号表示の有効設定取得クロージャ
    ///   - onTabNumbers: タブ番号マッピング変更時のコールバック
    ///   - seenPolicy: 閲覧時の既読化ポリシー取得クロージャ
    ///   - onSeen: 台帳への既読反映時のコールバック
    init(onFocus: @escaping (String?) -> Void,
         onDirectory: @escaping (String?) -> Void,
         wantsTabNumbers: @escaping () -> Bool,
         onTabNumbers: @escaping ([String: Int]) -> Void,
         seenPolicy: @escaping () -> MarkSessionSeen.Policy,
         onSeen: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // iTerm2 が最前面にない場合は Apple Event の通信コストおよび誤った既読化を防ぐため問い合わせをスキップする
                guard ItermBridge.isItermFrontmost else { return }

                // 取得失敗時は前回の値を維持し、一時的な通信遅延によるチラつきを防ぐ
                if let tab = ItermBridge.focusedTab(withTabNumbers: wantsTabNumbers()) {
                    let resolved = tab.session.isEmpty ? nil : tab.session
                    if resolved != self.current {
                        self.current = resolved
                        onFocus(resolved)
                    }
                    // リモート接続等でカレントディレクトリが取得できない場合は前回の値を維持する
                    if !tab.directory.isEmpty, tab.directory != self.currentDirectory {
                        self.currentDirectory = tab.directory
                        onDirectory(tab.directory)
                    }
                    // タブ全閉時などタブ番号が空になった場合も最新状態として通知する
                    if tab.tabNumbers != self.tabNumbers {
                        self.tabNumbers = tab.tabNumbers
                        onTabNumbers(tab.tabNumbers)
                    }
                }
                // メインスレッドのブロックを防ぐため台帳書き込みはバックグラウンドで行う
                let session = self.current
                let policy = seenPolicy()
                self.writer.submit({
                    (try? MarkSessionSeen.mark(itermSession: session, policy: policy)) == true
                }, changed: onSeen)
            }
        }
    }

    deinit { timer?.invalidate() }
}
