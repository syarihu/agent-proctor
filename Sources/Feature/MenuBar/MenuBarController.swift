import AppKit
import AppState
import Combine
import DesignSystem
import Model
import Resources

/// メニューバーにエージェントの状態要約（実行中・待機中等）を表示し、コンテキストメニューを提供するコントローラ。
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let store: TaskStore
    private var cancellable: AnyCancellable?
    private var appearanceObserver: NSKeyValueObservation?

    public var onToggleSidebar: (() -> Void)?
    /// サイドバーが非表示状態かどうか（メニュー文言の切り替え用）
    public var isSidebarHidden: (() -> Bool)?
    public var onOpenTask: ((String) -> Void)?
    public var onOpenSettings: (() -> Void)?

    public init(store: TaskStore) {
        self.store = store
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        // メニュー項目は表示要求時（menuNeedsUpdate）に動的構築する
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        cancellable = store.$summary.sink { [weak self] summary in
            self?.render(summary)
        }

        // 外観（Light/Dark）切り替え時にアイコン画像を適切な文字色で再描画する
        appearanceObserver = item.button?.observe(\.effectiveAppearance) {
            [weak self] _, _ in
            Task { @MainActor in self?.render(self?.store.summary ?? []) }
        }

        render(store.summary)
    }

    private func render(_ summary: [(status: String, count: Int)]) {
        item.isVisible = true
        // 通知対象のタスクがない場合でも、設定・終了操作へのエントリポイントを維持するため常駐シンボルを表示する
        guard !summary.isEmpty else {
            item.button?.attributedTitle = StatusGlyph.idleLine(
                defaultTint: menuBarTextColor())
            return
        }
        item.button?.attributedTitle = StatusGlyph.summaryLine(
            summary, defaultTint: menuBarTextColor())
    }

    /// 現在のメニューバー外観に応じた文字色を取得する
    private func menuBarTextColor() -> NSColor {
        guard let appearance = item.button?.effectiveAppearance else { return .labelColor }
        var color = NSColor.labelColor
        appearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
        }
        return color
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for entry in buildMenu().items {
            entry.menu?.removeItem(entry)
            menu.addItem(entry)
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // メニュー表示の遅延を防ぐため、git 呼び出しのない store.records（台帳オンメモリ値）を使用する
        let tasks = store.records
        if tasks.isEmpty {
            menu.addItem(withTitle: Localized.text("common.no_agents"),
                         action: nil, keyEquivalent: "")
        } else {
            for task in tasks {
                let entry = NSMenuItem(title: "",
                                       action: #selector(openTask(_:)), keyEquivalent: "")
                entry.image = StatusGlyph.menuIcon(for: task.displayStatus)
                entry.title = task.displayName
                entry.target = self
                entry.representedObject = task.id
                entry.toolTip = "\(task.branch) — \(task.worktree)"
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        let hidden = isSidebarHidden?() ?? false
        let toggle = NSMenuItem(
            title: Localized.text(hidden ? "app.menu.show_sidebar" : "app.menu.hide_sidebar"),
            action: #selector(toggleSidebar), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(title: Localized.text("app.menu.settings"),
                                  action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: Localized.text("app.menu.quit"),
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
