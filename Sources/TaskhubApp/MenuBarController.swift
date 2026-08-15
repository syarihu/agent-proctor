import AppKit
import Combine
import ServiceManagement
import TaskhubKit

/// メニューバーの要約。
///
/// もともと iTerm2 のステータスバーに出していた「▶2 ⏳1」を引き継ぐもの。
/// 動いているものが無いときは項目ごと隠す。タブ色と同じで
/// 「印が出ている = 見るべきものがある」という引き算にそろえる。
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: TaskStore
    private let appearance: Appearance
    private var cancellable: AnyCancellable?

    var onToggleSidebar: (() -> Void)?
    var onOpenTask: ((String) -> Void)?

    init(store: TaskStore, appearance: Appearance) {
        self.store = store
        self.appearance = appearance
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
        render(store.summary)
    }

    private func render(_ summary: [(status: String, count: Int)]) {
        guard !summary.isEmpty else {
            item.isVisible = false
            return
        }
        item.isVisible = true
        item.button?.title = summary
            .map { "\(Status.mark($0.status))\($0.count)" }
            .joined(separator: " ")
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

        // 一覧は台帳から直に作る。ここで git を起動すると
        // メニューを開くたびに固まる
        let tasks = Ledger.loadTasks()
        if tasks.isEmpty {
            menu.addItem(withTitle: "動いているエージェントはいません", action: nil, keyEquivalent: "")
        } else {
            for task in tasks {
                let title = "\(Status.mark(task.status))  \(task.name ?? task.id)"
                let entry = NSMenuItem(title: title,
                                       action: #selector(openTask(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = task.id
                entry.toolTip = "\(task.branch) — \(task.worktree)"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "サイドバーの表示",
                                action: #selector(toggleSidebar), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 文字の大きさ。余白も追従するので、行の高さごと変わる
        let size = NSMenuItem(title: "文字の大きさ (\(Int(appearance.fontSize)))",
                              action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        // 上限・下限に達したら選べなくしたい。既定のままだと
        // target/action があるだけで有効になってしまう
        sizeMenu.autoenablesItems = false
        let bigger = NSMenuItem(title: "大きく", action: #selector(growFont),
                                keyEquivalent: "+")
        bigger.target = self
        bigger.isEnabled = appearance.canGrow
        sizeMenu.addItem(bigger)

        let smaller = NSMenuItem(title: "小さく", action: #selector(shrinkFont),
                                 keyEquivalent: "-")
        smaller.target = self
        smaller.isEnabled = appearance.canShrink
        sizeMenu.addItem(smaller)

        sizeMenu.addItem(.separator())
        let reset = NSMenuItem(title: "もとに戻す (\(Int(Appearance.defaultSize)))",
                               action: #selector(resetFont), keyEquivalent: "0")
        reset.target = self
        sizeMenu.addItem(reset)

        size.submenu = sizeMenu
        menu.addItem(size)

        let login = NSMenuItem(title: "ログイン時に起動",
                               action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Taskhub を終了",
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

    @objc private func growFont() { appearance.grow() }
    @objc private func shrinkFont() { appearance.shrink() }
    @objc private func resetFont() { appearance.reset() }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "ログイン項目を変更できませんでした"
            alert.informativeText = "\(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
