import AppKit
import Combine
import ProctorKit

/// メニューバーの要約。
///
/// もともと iTerm2 のステータスバーに出していた「▶2 ⏳1」を引き継ぐもの。
/// 知らせることが無いときは数字を出さず、静かな記号だけにする。タブ色と同じで
/// 「印が出ている = 見るべきものがある」という引き算にそろえる。
/// (項目そのものは残す。メニューが設定と終了の唯一の入口なので、
///  消すと何も動いていないときに触れなくなる)
///
/// 記号の描き方は StatusGlyph が持つ。一覧では絵文字を使っているが、
/// メニューバーでは字幅の揃う SF Symbols に置き換えている。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: TaskStore
    private var cancellable: AnyCancellable?
    private var appearanceObserver: NSKeyValueObservation?

    var onToggleSidebar: (() -> Void)?
    /// 手で閉じられているか。メニューの文言を決めるのに使う
    var isSidebarHidden: (() -> Bool)?
    var onOpenTask: ((String) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(store: TaskStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        // 中身は開かれたときに組み直す。要約が変わった瞬間にしか作らないと、
        // 何も変わっていないあいだに開いたときに古い一覧が出る
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        cancellable = store.$summary.sink { [weak self] summary in
            self?.render(summary)
        }

        // 記号の色は描いた時点の地色で焼き込まれるので、
        // ライト/ダークが切り替わったら描き直さないと沈んで見えなくなる
        appearanceObserver = item.button?.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            Task { @MainActor in self?.render(self?.store.summary ?? []) }
        }

        render(store.summary)
    }

    private func render(_ summary: [(status: String, count: Int)]) {
        item.isVisible = true
        // 知らせることが無いときも、静かな印だけ残して居場所は明け渡さない。
        // メニューは設定・サイドバー切替・終了の唯一の入口なので、
        // 消してしまうと何も動いていないときに触れなくなる
        guard !summary.isEmpty else {
            item.button?.attributedTitle = StatusGlyph.idleLine(
                defaultTint: menuBarTextColor())
            return
        }
        // 記号は SF Symbols を画像として差し込む (StatusGlyph)。
        // 絵文字を文字列で並べると字幅が揃わず、数が変わるたびにバーが揺れる。
        //
        // 画像はテンプレートとして扱われないので、地色に合う色をこちらで解決して渡す。
        // メニューバーはシステムのライト/ダークとは別に暗くなることがあるので、
        // ボタン自身の見え方を基準にする
        item.button?.attributedTitle = StatusGlyph.summaryLine(
            summary, defaultTint: menuBarTextColor())
    }

    /// メニューバーの文字色。今の見え方に合わせて解決する
    private func menuBarTextColor() -> NSColor {
        guard let appearance = item.button?.effectiveAppearance else { return .labelColor }
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in buildMenu().items {
            // 別のメニューから移すには、いったん外さないと入れられない
            entry.menu?.removeItem(entry)
            menu.addItem(entry)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // 一覧は Store が持っている台帳から作る。ここで git を起動すると
        // メニューを開くたびに固まるので、数えた一覧 (store.tasks) は使わない
        let tasks = store.records
        if tasks.isEmpty {
            menu.addItem(withTitle: "動いているエージェントはいません", action: nil, keyEquivalent: "")
        } else {
            for task in tasks {
                let entry = NSMenuItem(title: "",
                                       action: #selector(openTask(_:)), keyEquivalent: "")
                // 項目の頭にも同じ記号を出す。メニューバーの数字と見比べたときに
                // どれが確認待ちなのかを字面で対応させたい
                entry.image = StatusGlyph.menuIcon(for: task.displayStatus)
                entry.title = task.name ?? task.id
                entry.target = self
                entry.representedObject = task.id
                entry.toolTip = "\(task.branch) — \(task.worktree)"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        // 「表示」のままだと、出ているのか消えているのか字面で分からない。
        // 押したら何が起きるかを書く (macOS のツールバー表示と同じ流儀)
        let hidden = isSidebarHidden?() ?? false
        let toggle = NSMenuItem(title: hidden ? "サイドバーを表示" : "サイドバーを隠す",
                                action: #selector(toggleSidebar), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 設定はここには並べない。文字の大きさのように少しずつ動かして
        // 確かめたいものは、メニューだと開き直すたびに手が止まる
        let settings = NSMenuItem(title: "設定...",
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Agent Proctor を終了",
                              action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openTask(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onOpenTask?(id)
    }

    @objc private func toggleSidebar() { onToggleSidebar?() }

    @objc private func openSettings() { onOpenSettings?() }

    @objc private func quit() { NSApp.terminate(nil) }
}
