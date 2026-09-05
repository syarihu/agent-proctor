import AppKit
import AppState
import DesignSystem
import Model
import Resources
import SwiftUI
import UseCaseTask

/// サイドバーに出す一覧。
///
/// 見せているのは「タブを見ても分からない情報」に絞っている。
/// セッション名・コンテキスト使用率・サブエージェントの数、そして
/// 最後に状態が動いてからの経過時間。実行中のまま経過が長ければ、
/// 考え込んでいるのか止まっているのかの手がかりになる。
public struct TaskListView: View {
    @ObservedObject public var store: TaskStore
    @ObservedObject public var appearance: Appearance
    @ObservedObject public var folding: GroupFolding
    @ObservedObject public var avatars: OrgAvatarStore
    @ObservedObject public var pullRequests: PullRequestStore
    public var onOpen: (CollectedTask) -> Void
    public var onClose: (CollectedTask) -> Void
    /// セッションの乗っていない worktree を押したとき。
    /// 戻る先のタブが無いので、そこへ移動した新しいタブを開く
    public var onOpenWorktree: (CollectedWorktree) -> Void
    /// リポジトリの見出しの `+` を押したとき。そのリポジトリで新しいタブを開く
    public var onNewTab: (_ path: String, _ name: String) -> Void
    /// 要確認から片付けるとき。渡した分だけ台帳の状態まで動く
    public var onClearAttention: ([CollectedTask]) -> Void

    public init(store: TaskStore, appearance: Appearance, folding: GroupFolding,
                avatars: OrgAvatarStore, pullRequests: PullRequestStore,
                onOpen: @escaping (CollectedTask) -> Void,
                onClose: @escaping (CollectedTask) -> Void,
                onOpenWorktree: @escaping (CollectedWorktree) -> Void,
                onNewTab: @escaping (_ path: String, _ name: String) -> Void,
                onClearAttention: @escaping ([CollectedTask]) -> Void) {
        self.store = store
        self.appearance = appearance
        self.folding = folding
        self.avatars = avatars
        self.pullRequests = pullRequests
        self.onOpen = onOpen
        self.onClose = onClose
        self.onOpenWorktree = onOpenWorktree
        self.onNewTab = onNewTab
        self.onClearAttention = onClearAttention
    }

    /// 文字の大きさはここだけで決める。余白も記号もこれに追従する。
    /// メニューバーから変えられる (Appearance)
    private var base: CGFloat { appearance.fontSize }

    public var body: some View {
        // body 内でグルーピング計算を1度だけ行い、ForEach と animation での重複計算を防ぐ
        let byOrg = appearance.resolvedGrouping == .organization
        let orgs = byOrg ? orgGroups : []
        let repos = byOrg ? [] : repoGroups
        let limits = rateLimitSummaries
        // 要確認タスクはグルーピングモードに関わらず最上部に表示する
        let pending = CollectTasks.awaitingReview(store.tasks)
        let ordering = orderKey(orgs: orgs, repos: repos)
        return ZStack {
            // 背景のアンビエントグロー（確認待ちや実行中の状態に応じた環境光）
            ambientGlow

            VStack(spacing: 0) {
                if !pending.isEmpty {
                    AttentionInbox(
                        tasks: pending, base: base, avatars: avatars,
                        mode: byOrg ? .organization : .repository,
                        unknownTitle: Localized.text("app.group.no_organization"),
                        onOpen: onOpen, onClear: onClearAttention)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ScrollView {
                    // タスクが空でも残存 worktree がある場合は空表示にしない
                    if store.tasks.isEmpty && (byOrg ? orgs.isEmpty : repos.isEmpty) {
                        Text(Localized.text("common.no_agents"))
                            .font(.system(size: base * 0.9))
                            .foregroundStyle(Palette.dim)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, base * 0.4)
                            .padding(.vertical, base * 0.6)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            if byOrg {
                                ForEach(orgs) { org in
                                    OrgHeader(
                                        group: org,
                                        base: base,
                                        avatars: avatars,
                                        collapsed: folding.isCollapsed(org.id),
                                        tally: TaskStatus.counts(
                                            displayStatuses: org.tasks.map(\.displayStatus)),
                                        onToggle: { toggle(org.id) })
                                    if !folding.isCollapsed(org.id) {
                                        ForEach(org.repos) { repo in
                                            repoSection(repo, indent: base * 0.7)
                                        }
                                    }
                                }
                            } else {
                                ForEach(repos) { repo in
                                    repoSection(repo, indent: 0)
                                }
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.78),
                                   value: ordering)
                    }
                }
                .padding(base * 0.3)

                if !limits.isEmpty {
                    RateLimitFooter(summaries: limits, base: base)
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.82),
                       value: pending.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 一覧から除外された worktree の PR キャッシュを破棄する
        .onChange(of: ordering) { _ in
            pullRequests.keep(worktrees: Set(store.tasks.map(\.worktree)))
        }
    }

    private var rateLimitSummaries: [AgentQuotaSummary] {
        store.rateLimitSummaries
    }

    /// リポジトリの見出しとタスク行（1段まとめ・2段まとめ共通コンポーネント）
    @ViewBuilder
    private func repoSection(_ group: RepoGroup, indent: CGFloat) -> some View {
        let folded = isFolded(group)
        let empty = group.tasks.isEmpty && group.worktrees.isEmpty
        RepoHeader(
            name: group.name,
            repo: group.id,
            base: base,
            topSpacing: indent > 0 ? base * 0.15 : base * 0.3,
            collapsed: folded,
            foldable: !empty,
            tally: TaskStatus.counts(displayStatuses: group.tasks.map(\.displayStatus)),
            worktrees: group.worktrees.count,
            onToggle: { toggleRepo(group) },
            onNewTab: { onNewTab(group.id, group.name) })
            .padding(.leading, indent)
        if !folded {
            ForEach(group.tasks) { task in
                TaskRow(task: task, base: base,
                        isCurrent: isCurrent(task),
                        tabNumber: tabNumber(task),
                        pullRequests: pullRequests,
                        onOpen: onOpen, onClose: onClose)
                    .padding(.leading, base + indent)
            }
            if !group.worktrees.isEmpty {
                // リポジトリ本体パスと重複しないよう "wt:" プレフィックスを付与する
                let key = "wt:" + group.id
                let open = folding.isExpanded(key)
                WorktreeSummaryRow(
                    worktrees: group.worktrees, base: base,
                    expanded: open,
                    onToggle: { toggleExpanded(key) })
                    .padding(.leading, base * 0.6 + indent)
                if open {
                    ForEach(group.worktrees) { worktree in
                        WorktreeRow(worktree: worktree, base: base, onOpen: onOpenWorktree)
                            .padding(.leading, base + indent)
                    }
                }
            }
        }
    }

    /// 現在 iTerm2 で選択中のタブかどうかを判定する（未設定値同士の誤一致による全行ハイライトを防ぐ）。
    private func isCurrent(_ task: CollectedTask) -> Bool {
        guard let focused = store.focusedSession, !focused.isEmpty else { return false }
        return task.itermSession == focused
    }

    /// セッションに対応する iTerm2 タブ番号（⌘N）
    private func tabNumber(_ task: CollectedTask) -> Int? {
        guard appearance.showTabNumbers else { return nil }
        guard let session = task.itermSession, !session.isEmpty else { return nil }
        return store.tabNumbers[session]
    }

    /// リポジトリの見出しが折りたたまれているか。
    /// セッションが存在する間はデフォルト展開（isCollapsed で判定）、
    /// セッション終了後はデフォルト折りたたみ（isExpanded で判定）へ自動的に切り替える。
    private func isFolded(_ group: RepoGroup) -> Bool {
        group.tasks.isEmpty ? !folding.isExpanded(group.id) : folding.isCollapsed(group.id)
    }

    /// リポジトリ見出しの折りたたみ切り替え。isFolded と整合させ、タスクの有無に応じて対象の集合を切り替える。
    private func toggleRepo(_ group: RepoGroup) {
        if group.tasks.isEmpty {
            toggleExpanded(group.id)
        } else {
            toggle(group.id)
        }
    }

    /// 折りたたみの開閉アニメーション
    private func toggle(_ group: String) {
        withAnimation(.easeOut(duration: 0.18)) { folding.toggle(group) }
    }

    /// デフォルト折りたたみ項目の開閉アニメーション
    private func toggleExpanded(_ group: String) {
        withAnimation(.easeOut(duration: 0.18)) { folding.toggleExpanded(group) }
    }

    /// 並び順の変化をアニメーションに伝える識別キーを生成する
    private func orderKey(orgs: [OrgGroup], repos: [RepoGroup]) -> String {
        func key(_ repos: [RepoGroup]) -> String {
            repos.map { "\($0.id):" + $0.tasks.map(\.id).joined(separator: ",") }
                .joined(separator: "|")
        }
        if appearance.resolvedGrouping == .organization {
            return "org|" + orgs.map { "\($0.id)>" + key($0.repos) }.joined(separator: "//")
        }
        return "repo|" + key(repos)
    }

    private var repoGroups: [RepoGroup] {
        TaskGrouping.byRepository(store.tasks, worktrees: store.worktrees,
                                  keeping: store.keptRepos)
    }

    private var orgGroups: [OrgGroup] {
        TaskGrouping.byOrganization(
            store.tasks, worktrees: store.worktrees, keeping: store.keptRepos,
            unknownTitle: Localized.text("app.group.no_organization"))
    }

    /// 確認待ち（オレンジ）や実行中（ブルー）のタスクがあるとき、
    /// サイドバーの縁にほのかに色を差して注意を引きやすくする
    @ViewBuilder
    private var ambientGlow: some View {
        if store.tasks.contains(where: { $0.status == TaskStatus.waiting }) {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.waiting.opacity(0.18), lineWidth: 1.5)
                .ignoresSafeArea()
        } else if store.tasks.contains(where: { $0.status == TaskStatus.running }) {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Palette.spinner.opacity(0.08), lineWidth: 1.0)
                .ignoresSafeArea()
        }
    }
}

/// Organization ごとの見出し。押すと配下のリポジトリを折りたたむ。
/// アイコン、太字、上部余白でリポジトリ見出しとの階層差を付ける。
/// 主要素であるセッション名より大きくすると視覚的な優先順序が逆転するため、フォントサイズは同等以下に抑える。
private struct OrgHeader: View {
    let group: OrgGroup
    let base: CGFloat
    @ObservedObject var avatars: OrgAvatarStore
    let collapsed: Bool
    /// 折りたたみ時に表示するグループ内のステータス別件数
    let tally: [(status: String, count: Int)]
    var onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: base * 0.3) {
            Image(systemName: "chevron.right")
                .font(.system(size: base * 0.7, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: base * 0.8)

            OrgAvatar(owner: group.owner, host: group.host, title: group.title,
                      size: base * 1.05, avatars: avatars)

            Text(group.title)
                .font(.system(size: base * 0.9, weight: .semibold))
                .foregroundStyle(Palette.fg)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: base * 0.3)

            if collapsed {
                HStack(spacing: base * 0.35) {
                    ForEach(tally, id: \.status) { entry in
                        Text("\(TaskStatus.mark(entry.status))\(entry.count)")
                            .foregroundStyle(Palette.status(entry.status))
                    }
                }
                .font(.system(size: base * 0.8).monospacedDigit())
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: base * 0.3)
                .fill(hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .padding(.top, base * 0.5)
    }
}

/// Organization のアバターアイコン。
/// 画像の取得前や取得不可時は頭文字を描画する。画像取得後に見出し文字が横へずれるのを防ぐため、領域は常に確保する。
private struct OrgAvatar: View {
    /// GitHub の login 名（不明な場合は nil）
    let owner: String?
    let host: String?
    /// モノグラム表示用のタイトル
    let title: String
    let size: CGFloat
    @ObservedObject var avatars: OrgAvatarStore

    var body: some View {
        Group {
            if let owner, let image = avatars.images[owner] {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                monogram
            }
        }
        .frame(width: size, height: size)
        // 組織アイコンの四角い図案の欠けを防ぎ、GitHub の表示に合わせるため角丸にする
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        // 描画中の状態変更を防ぐため、画像の非同期取得は body ではなく task で行う
        .task(id: owner) {
            guard let owner, let host else { return }
            await avatars.load(owner: owner, host: host)
        }
    }

    private var monogram: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Palette.hover)
            Text(title.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.6, weight: .semibold))
                .foregroundStyle(Palette.dim)
        }
    }
}

/// プロジェクトごとの見出し。
/// 畳んでいる間も確認待ちの見落としを防ぐため、状態の内訳を表示する。
/// リポジトリ内の全件数を把握できるよう、確認済み (✔) も含めて集計する。
private struct RepoHeader: View {
    let name: String
    /// リポジトリのパス（ツールチップ表示および識別キー用）
    let repo: String
    let base: CGFloat
    /// 前のグループとの間隔
    let topSpacing: CGFloat
    let collapsed: Bool
    /// 中身が空の場合は折りたたみ不能（シェブロン非表示）とする
    let foldable: Bool
    /// 畳んでいるときに出す内訳（確認済みを含む）
    let tally: [(status: String, count: Int)]
    /// セッションの乗っていない worktree の数（畳んだ状態での見落としを防ぐため表示）
    let worktrees: Int
    var onToggle: () -> Void
    var onNewTab: () -> Void

    @State private var hovering = false
    @State private var plusHovering = false

    var body: some View {
        HStack(spacing: base * 0.3) {
            if foldable {
                // 開閉時の記号切り替えによる視覚的なブレを防ぐため回転で向きを変える
                Image(systemName: "chevron.right")
                    .font(.system(size: base * 0.7, weight: .semibold))
                    .foregroundStyle(Palette.dim)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .frame(width: base * 0.8)
            } else {
                // シェブロン非表示時も見出しの左端インデントを揃えるため幅を確保する
                Color.clear.frame(width: base * 0.8, height: 1)
            }

            // 主要素であるセッション名との視覚的な優先関係を保つため、見出しはわずかに小さくする
            Text(name)
                .font(.system(size: base * 0.9, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: base * 0.3)

            if collapsed {
                HStack(spacing: base * 0.35) {
                    ForEach(tally, id: \.status) { entry in
                        Text("\(TaskStatus.mark(entry.status))\(entry.count)")
                            .foregroundStyle(Palette.status(entry.status))
                    }
                    // worktree はタスク状態を持たないため、ステータス色や記号との混同を防ぐ専用の記号・色を使う
                    if worktrees > 0 {
                        Text("⌁\(worktrees)")
                            .foregroundStyle(Palette.dim)
                    }
                }
                .font(.system(size: base * 0.8).monospacedDigit())
                .layoutPriority(1)
            }

            // 折りたたみ状態によってボタン位置が左右に揺れないよう最右端に配置する
            newTabButton
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: base * 0.3)
                .fill(hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 中身のない見出しは折りたたみ操作を行わない。ただし + ボタンの操作や所属リポジトリの認識のため行表示とツールチップは維持する
        .onTapGesture { if foldable { onToggle() } }
        .help(repo)
        // ホバー背景やタップ判定の領域が不要に広がるのを防ぐため、余白はタップ範囲の外側に設ける
        .padding(.top, topSpacing)
    }

    /// ホバー時のみ表示する新規タブ追加ボタン。
    /// 見出しの onTapGesture と競合せず内側のタップを優先させ、かつ nonactivatingPanel 上で1回目のクリックを拾うため、Button ではなく onTapGesture を使用する。
    @ViewBuilder
    private var newTabButton: some View {
        Image(systemName: "plus")
            .font(.system(size: base * 0.8, weight: .semibold))
            .foregroundStyle(plusHovering ? Palette.fg : Palette.dim)
            // タップ判定領域を広げて押しやすくする
            .padding(base * 0.2)
            .contentShape(Rectangle())
            .onHover { plusHovering = $0 }
            .onTapGesture(perform: onNewTab)
            .help(Localized.text("app.repo.new_tab", repo))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// セッションの乗っていない worktree のサマリー行。
/// アクティブなセッションと混同しないよう控えめなスタイルで表示する。
private struct WorktreeSummaryRow: View {
    let worktrees: [CollectedWorktree]
    let base: CGFloat
    let expanded: Bool
    var onToggle: () -> Void

    @State private var hovering = false

    private var removable: Int { worktrees.filter(\.isRemovable).count }

    var body: some View {
        HStack(spacing: base * 0.3) {
            Image(systemName: "chevron.right")
                .font(.system(size: base * 0.6, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: base * 0.7)

            Text(Localized.text("app.worktrees.summary", worktrees.count))
                .font(.system(size: base * 0.75))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)

            // 不要なノイズを防ぐため、削除可能な worktree が存在する場合のみ件数を表示する
            if removable > 0 {
                Text(Localized.text("app.worktrees.removable", removable))
                    .font(.system(size: base * 0.75))
                    .foregroundStyle(Palette.done)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: base * 0.3)
                .fill(hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
    }
}

/// セッションが乗っていない worktree の行。押すと対象ディレクトリを開く
private struct WorktreeRow: View {
    let worktree: CollectedWorktree
    let base: CGFloat
    var onOpen: (CollectedWorktree) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: base * 0.4) {
            // タスクステータス記号との混同を防ぐため、専用の記号（⌁）と色を使用する
            Text("⌁")
                .font(.system(size: base * 0.8))
                .foregroundStyle(Palette.dim)
                .frame(width: base * 1.0, alignment: .center)

            VStack(alignment: .leading, spacing: base * 0.1) {
                Text(worktree.name)
                    .font(.system(size: base * 0.85))
                    .foregroundStyle(Palette.dim)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: base * 0.35) {
                    Text(Localized.text("app.row.branch_age",
                                        worktree.branch ?? "-",
                                        shortAge(worktree.idleSeconds)))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if worktree.isLocked {
                        Text(Localized.text("app.worktree.locked"))
                    } else if worktree.isRemovable {
                        Text(Localized.text("app.worktree.removable"))
                            .foregroundStyle(Palette.done)
                    } else if worktree.merged, worktree.diffKnown {
                        // diff 未計測時は誤判定（未コミット変更の有無や squash merge など）を防ぐためマージ済み表示を行わない。
                        // 視認性を確保するため PR マージと同じ配色を使用する
                        Text(Localized.text("app.worktree.merged"))
                            .foregroundStyle(Palette.prMerged)
                    }

                    if !worktree.diff.isEmpty {
                        if worktree.diff.added > 0 {
                            Text("+\(worktree.diff.added)").foregroundStyle(Palette.added)
                        }
                        if worktree.diff.removed > 0 {
                            Text("-\(worktree.diff.removed)").foregroundStyle(Palette.removed)
                        }
                        if worktree.diff.untracked > 0 {
                            Text("?\(worktree.diff.untracked)").foregroundStyle(Palette.untracked)
                        }
                        if worktree.diff.binary > 0 {
                            Text("~\(worktree.diff.binary)").foregroundStyle(Palette.binary)
                        }
                    }
                }
                .font(.system(size: base * 0.7).monospacedDigit())
                .foregroundStyle(Palette.dim)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: base * 0.3)
                .fill(hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen(worktree) }
        .help(Localized.text("app.worktree.open_help", worktree.path))
    }
}

private struct TaskRow: View {
    let task: CollectedTask
    let base: CGFloat
    /// いま iTerm2 で開いているタブ
    let isCurrent: Bool
    /// このセッションが乗っているタブの番号 (⌘N の N)。聞けていない間は nil
    let tabNumber: Int?
    @ObservedObject var pullRequests: PullRequestStore
    var onOpen: (CollectedTask) -> Void
    var onClose: (CollectedTask) -> Void

    @State private var hovering = false
    @State private var diving = false
    /// 閉じるボタンの上にいるか。行のホバーとは別に持つ (色を変えるため)
    @State private var closeHovering = false

    /// 確認済みタスクは視覚的優先度を下げる（アクティブな現在タブを除く）
    private var isDimmed: Bool { task.displayStatus == TaskStatus.seen && !isCurrent }

    var body: some View {
        HStack(alignment: .top, spacing: base * 0.4) {
            // 横幅を圧迫しないよう、ステータス記号の下にタブ番号を縦に配置する
            VStack(spacing: base * 0.2) {
                mark
                tabShortcut
            }
                .frame(width: base * 1.3, alignment: .center)
                .padding(.top, base * 0.12)

            VStack(alignment: .leading, spacing: base * 0.15) {
                // エージェント名・モデル名・コンテキストミニバー
                HStack(alignment: .center, spacing: base * 0.25) {
                    agentIcon
                    Text(task.agentDisplayName)
                        .font(.system(size: base * 0.7, weight: .medium))
                        .foregroundStyle(Palette.dim)

                    if let model = task.model {
                        Text("·")
                            .font(.system(size: base * 0.7))
                            .foregroundStyle(Palette.dim)
                        Text(model)
                            .font(.system(size: base * 0.7))
                            .foregroundStyle(Palette.dim)
                            .lineLimit(1)
                    }

                    if let percent = task.contextPercent {
                        Text("·")
                            .font(.system(size: base * 0.7))
                            .foregroundStyle(Palette.dim)
                        ContextMiniBar(percent: percent, base: base)
                    }
                }

                // セッション名（タイトル）
                HStack(alignment: .firstTextBaseline, spacing: base * 0.5) {
                    Text(task.displayName)
                        .font(.system(size: base, weight: .semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // PR・ブランチ・経過時間・サブエージェント・diff
                HStack(alignment: .firstTextBaseline, spacing: base * 0.6) {
                    // 横幅不足時に PR 番号の欠落を防ぐため優先度を上げる（ブランチ名末尾を切り詰め対象にする）
                    if let pr = pullRequests.refs[task.worktree] {
                        PRBadge(ref: pr, base: base).layoutPriority(1)
                    }
                    Text(Localized.text("app.row.branch_age", task.branch, shortAge(task.idleSeconds)))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if task.subagents > 0 {
                        Text("🤖\(task.subagents)")
                            .foregroundStyle(Palette.agents)
                            .pulsing()
                            .layoutPriority(1)
                    }
                    Spacer(minLength: base * 0.25)
                    diffView.layoutPriority(1)
                }
                .font(.system(size: base * 0.8))
                .foregroundStyle(Palette.dim)

                // 承認待ちのリクエスト内容。実行中ツールの表示（currentActivity）と視覚的に区別する
                if let request = task.currentRequest {
                    Text(request)
                        .font(.system(size: base * 0.75).monospaced())
                        .foregroundStyle(Palette.waiting)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 実行中ツール。頻繁に更新されるためアニメーションは適用しない
                if let activity = task.currentActivity {
                    Text(activity)
                        .font(.system(size: base * 0.75).monospaced())
                        .foregroundStyle(Palette.activity)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 実行中のサブエージェント一覧
                if !task.currentSubagents.isEmpty {
                    VStack(alignment: .leading, spacing: base * 0.2) {
                        ForEach(Array(task.currentSubagents.enumerated()), id: \.element.id) {
                            index, sub in
                            SubagentRow(sub: sub, base: base,
                                        isLast: index == task.currentSubagents.count - 1)
                        }
                    }
                    .padding(.top, base * 0.1)
                }
            }
            .opacity(isDimmed ? 0.45 : 1)
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 行全体のレイアウト幅の変動による文字揺れを防ぐためオーバーレイで配置する
        .overlay(alignment: .topTrailing) { closeButton }
        .background(
            ZStack {
                // 現在選択中のタブを示すインジケータ。タスク状態色との混同を防ぐ配色にする
                if isCurrent {
                    RoundedRectangle(cornerRadius: base * 0.3)
                        .fill(Palette.current)
                    HStack {
                        RoundedRectangle(cornerRadius: base * 0.1)
                            .fill(Palette.spinner)
                            .frame(width: max(2, base * 0.16))
                        Spacer(minLength: 0)
                    }
                }
                if hovering {
                    RoundedRectangle(cornerRadius: base * 0.3)
                        .fill(Palette.hover)
                }
                if diving {
                    // iTerm2 へフォーカス移動する際のエフェクト
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Palette.spinner.opacity(0.35), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: base * 0.3))
                }
            }
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) { diving = true }
            onOpen(task)
            Task {
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.easeOut(duration: 0.2)) { diving = false }
            }
        }
        .help(task.worktree)
        // タスク行の表示期間中のみ PR 情報を監視する
        .task(id: task.worktree) {
            await pullRequests.watch(worktree: task.worktree, origin: task.origin)
        }
        // ターンの終了直後に PR 情報を再取得する。タブ閲覧による seen 化などでの不要な gh 呼び出しを防ぐため、台帳の task.status を監視する
        .onChange(of: task.status) { status in
            guard task.exists,
                  status == TaskStatus.done || status == TaskStatus.failed else { return }
            pullRequests.noteTurnEnded(worktree: task.worktree, origin: task.origin)
        }
    }

    /// ホバー時のみ表示する削除ボタン。台帳レコードのみを削除し worktree には影響しない。
    /// nonactivatingPanel 上で1回目のクリックを確実に拾うため、Button ではなく onTapGesture を使用する。
    @ViewBuilder
    private var closeButton: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: base * 0.85))
            .foregroundStyle(closeHovering ? Palette.removed : Palette.dim)
            // タップ判定領域を広げて押しやすくする
            .padding(base * 0.3)
            .contentShape(Rectangle())
            .onHover { closeHovering = $0 }
            .onTapGesture { onClose(task) }
            .help(Localized.text("app.row.close_help"))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// 未確認の完了や待機中のタスクを視覚的に強調する
    private var titleColor: Color {
        switch task.displayStatus {
        case TaskStatus.waiting: return Palette.waiting
        case TaskStatus.done: return Palette.done
        default: return Palette.fg
        }
    }

    @ViewBuilder
    private var agentIcon: some View {
        AgentIcon(agent: task.resolvedAgent, size: base * 0.7)
    }

    /// 実行中はスピナー、待機中は点滅、完了時はアニメーション付きチェックマークを表示する。
    /// 確認済みでも未完了（attentionStatus が done）の場合は、完了状態の識別を保つため緑色を維持する。
    @ViewBuilder
    private var mark: some View {
        switch task.displayStatus {
        case TaskStatus.running:
            Spinner(size: base)
        case TaskStatus.waiting:
            Text(TaskStatus.mark(task.displayStatus)).font(.system(size: base)).pulsing()
        case TaskStatus.done:
            // 未確認の完了タスクはタイトル色と統一する
            AnimatedCheckmark(size: base, color: Palette.done)
        case TaskStatus.seen:
            Text(TaskStatus.mark(task.displayStatus))
                .font(.system(size: base))
                .foregroundStyle(task.attentionStatus == TaskStatus.done ? Palette.done : Palette.fg)
                .opacity(task.attentionStatus == TaskStatus.done ? 1 : (isDimmed ? 0.45 : 1))
        default:
            Text(TaskStatus.mark(task.displayStatus)).font(.system(size: base))
        }
    }

    /// タブショートカット（⌘1〜⌘9）。10以降は iTerm2 のショートカットが割り当てられていないため数字のみ表示する。
    /// 桁落ちによる誤読を防ぐため fixedSize を指定する。
    @ViewBuilder
    private var tabShortcut: some View {
        if let tabNumber {
            Text(tabNumber <= 9 ? "⌘\(tabNumber)" : "\(tabNumber)")
                .font(.system(size: base * 0.62, weight: .medium).monospacedDigit())
                .foregroundStyle(isCurrent ? Palette.dim.opacity(0.9) : Palette.dim.opacity(0.55))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var diffView: some View {
        HStack(spacing: 4) {
            if task.diff.added > 0 {
                DiffBadge(prefix: "+", count: task.diff.added, color: Palette.added)
            }
            if task.diff.removed > 0 {
                DiffBadge(prefix: "-", count: task.diff.removed, color: Palette.removed)
            }
            if task.diff.untracked > 0 {
                DiffBadge(prefix: "?", count: task.diff.untracked, color: Palette.untracked)
            }
            if task.diff.binary > 0 {
                DiffBadge(prefix: "~", count: task.diff.binary, color: Palette.binary)
            }
        }
        .font(.system(size: base * 0.8).monospacedDigit())
    }

}

/// 親タスクにぶら下がるサブエージェント行。
/// 役割名（静的）と現在のアクティビティ（動的）を分けて2行で表示する。
private struct SubagentRow: View {
    let sub: CollectedSubagent
    let base: CGFloat
    /// 末尾エージェントのみツリー枝の形状（└）を変更する
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: base * 0.3) {
            Text(isLast ? "└" : "├")
                .font(.system(size: base * 0.75).monospaced())
                .foregroundStyle(Palette.agents.opacity(0.55))

            VStack(alignment: .leading, spacing: base * 0.1) {
                HStack(alignment: .firstTextBaseline, spacing: base * 0.3) {
                    Text(sub.name)
                        .font(.system(size: base * 0.72, weight: .medium))
                        .foregroundStyle(Palette.agents)
                        .layoutPriority(1)
                    if let label = sub.label {
                        Text(label)
                            .font(.system(size: base * 0.72))
                            .foregroundStyle(Palette.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: base * 0.3) {
                    // 起動直後などでアクティビティが未取得の場合も行高の揺れを防ぐため経過時間は常に表示する
                    if let activity = sub.activity {
                        Text(activity)
                            .font(.system(size: base * 0.68).monospaced())
                            .foregroundStyle(Palette.activity)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(shortAge(sub.elapsedSeconds))
                        .font(.system(size: base * 0.68).monospacedDigit())
                        .foregroundStyle(Palette.dim)
                        .layoutPriority(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 秒数を短縮表記に変換する
private func shortAge(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
}

/// コンテキスト使用率の文字とミニカプセルバー
private struct ContextMiniBar: View {
    let percent: Int
    let base: CGFloat

    private var barWidth: CGFloat { base * 1.8 }
    private var barHeight: CGFloat { max(3, base * 0.2) }

    var body: some View {
        HStack(spacing: base * 0.2) {
            Text("Context: \(percent)%")
                .font(.system(size: base * 0.7).monospacedDigit())
                .foregroundStyle(Palette.context(percent))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.gray.opacity(0.25))
                    Capsule()
                        .fill(Palette.context(percent))
                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(percent) / 100)))
                }
            }
            .frame(width: barWidth, height: barHeight)
        }
    }
}

/// 差分変更時にアニメーションするバッジ
private struct DiffBadge: View {
    let prefix: String
    let count: Int
    let color: Color

    @State private var prevCount: Int = 0
    @State private var popping = false

    var body: some View {
        Text("\(prefix)\(count)")
            .foregroundStyle(color)
            .scaleEffect(popping ? 1.28 : 1.0)
            .brightness(popping ? 0.35 : 0.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.52), value: popping)
            .onChange(of: count) { newCount in
                if newCount > prevCount && prevCount != 0 {
                    popping = true
                    Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        popping = false
                    }
                }
                prevCount = newCount
            }
            .onAppear { prevCount = count }
    }
}

/// ブランチ行に配置する PR バッジ。
/// git 関連の情報（ブランチ名や diff）と並列に扱い、セッション名行の切り詰めや色変化の影響を避ける。
private struct PRBadge: View {
    let ref: PullRequestRef
    let base: CGFloat

    @State private var hovering = false

    var body: some View {
        // 横幅節約のため PR プレフィックスは付けず番号のみ表示する
        Text("#\(ref.number)")
            .font(.system(size: base * 0.8).monospacedDigit())
            .foregroundStyle(Palette.pullRequest(ref))
            // ホバー時のみ下線を表示し、常時の情報ノイズを減らす
            .underline(hovering)
            // ブランチ名との余白バランスを保ちつつ、タップ判定を縦方向に広げる
            .padding(.vertical, base * 0.2)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // nonactivatingPanel 上で1回目のクリックを確実に拾うため、Button ではなく onTapGesture を使用する
            .onTapGesture { open() }
            .help(Localized.text("app.row.pr_help", String(ref.number), ref.title))
            // アクセシビリティ対応（Text へのリンク特性付与）
            .accessibilityElement()
            .accessibilityLabel("#\(ref.number) \(ref.title)")
            .accessibilityAddTraits(.isLink)
            .accessibilityAction { open() }
    }

    private func open() {
        guard let url = URL(string: ref.url) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// 完了時のチェックマークアニメーション
private struct AnimatedCheckmark: View {
    let size: CGFloat
    /// 未確認の完了時のみ強調色を指定する
    var color: Color = Palette.dim
    @State private var progress: CGFloat = 0

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: max(1.5, size * 0.14), lineCap: .round, lineJoin: .round))
            .frame(width: size * 0.8, height: size * 0.8)
            .onAppear {
                withAnimation(.easeOut(duration: 0.3)) {
                    progress = 1
                }
            }
    }
}

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.52))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.minY + rect.height * 0.86))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.92, y: rect.minY + rect.height * 0.18))
        return path
    }
}

/// 実行中スピナー
private struct Spinner: View {
    let size: CGFloat
    @State private var spinning = false

    /// サイズ変動に対応するため、線幅はサイズに対する比率で算出する
    private var lineWidth: CGFloat { max(1.5, size * 0.16) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.25), lineWidth: lineWidth)
            Circle()
                // 回転アニメーションが視認できるよう、円の一部（25%）のみを描画する
                .trim(from: 0, to: 0.25)
                .stroke(Palette.spinner,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false),
                           value: spinning)
        }
        // 線の外側へのはみ出しを防ぐため、線幅の半分だけ内側に余白を設ける
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .onAppear { spinning = true }
    }
}

/// 待機中や実行中サブエージェント向けの明滅モディファイア
private struct Pulsing: ViewModifier {
    @State private var faded = false

    func body(content: Content) -> some View {
        content
            .opacity(faded ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                       value: faded)
            .onAppear { faded = true }
    }
}

private extension View {
    func pulsing() -> some View { modifier(Pulsing()) }
}

/// サイドバー最上部の未確認通知エリア。未確認のセッションを1行ずつ並べる。
///
/// グループ化方式（リポジトリ / Organization）や折りたたみ状態に関わらず、
/// 確認待ちのセッションを最上部に固定して視認性を確保する。
///
/// 一覧と一緒にスクロールされないよう、ScrollView の外に配置している。
/// また、未対応項目が不可視化されるのを防ぐため、折りたたみ機能は持たせない
/// （完了チェックやタブフォーカスによる既読化で自動的に除外される）。
private struct AttentionInbox: View {
    /// CollectTasks.awaitingReview の順序を維持する
    let tasks: [CollectedTask]
    let base: CGFloat
    @ObservedObject var avatars: OrgAvatarStore
    /// 下部一覧と共通のグループ化方式
    let mode: GroupingMode
    let unknownTitle: String
    var onOpen: (CollectedTask) -> Void
    var onClear: ([CollectedTask]) -> Void

    /// 下部の一覧が押し出されるのを防ぐための表示件数上限
    private static let limit = 5

    var body: some View {
        let shown = Array(tasks.prefix(Self.limit))
        let rest = tasks.count - shown.count
        // 上限を適用した後にグルーピングを行うことで、グループ件数と表示件数の不整合を防ぐ
        let groups = TaskGrouping.pending(shown, by: mode, unknownTitle: unknownTitle)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: base * 0.1) {
                header
                ForEach(groups) { group in
                    InboxGroupCaption(group: group, base: base, avatars: avatars)
                    ForEach(group.tasks) { task in
                        // Organization 別表示時のみ、識別のためリポジトリ名を行内にも表示する
                        InboxRow(task: task, base: base,
                                 showsRepo: mode == .organization,
                                 onOpen: onOpen, onClear: { onClear([$0]) })
                    }
                }
                // 件数超過時に切り詰められたタスクが存在することを明示する
                if rest > 0 {
                    Text(Localized.text("app.inbox.more", rest))
                        .font(.system(size: base * 0.7))
                        .foregroundStyle(Palette.dim)
                        .padding(.horizontal, base * 0.4)
                }
            }
            // 下部の ScrollView と左端のインデントを揃え、上部に適切な余白を設ける
            .padding(.horizontal, base * 0.3)
            .padding(.top, base * 0.8)

            // コンテンツ余白と分離して境界線を端まで描画する
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1)
                .padding(.top, base * 0.45)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // アイテムの増減を視覚的に伝えるためのスプリングアニメーション
        .animation(.spring(response: 0.35, dampingFraction: 0.8),
                   value: tasks.map(\.id).joined(separator: ","))
    }

    /// 見出しと件数バッジ。最も緊急度の高いタスク（先頭要素）のステータス色をバッジ背景に適用する
    private var header: some View {
        HStack(spacing: base * 0.3) {
            Text(Localized.text("app.inbox.title"))
                .font(.system(size: base * 0.7, weight: .semibold))
                .foregroundStyle(Palette.dim)
            Text("\(tasks.count)")
                .font(.system(size: base * 0.65, weight: .bold).monospacedDigit())
                .foregroundStyle(Palette.fg)
                .padding(.horizontal, base * 0.3)
                .padding(.vertical, base * 0.05)
                .background(
                    Capsule().fill(
                        Palette.status(tasks.first?.attentionStatus ?? TaskStatus.waiting)
                            .opacity(0.35)))
            Spacer(minLength: 0)
            // 表示上限で切り詰められた分も含めて全件をクリア対象とする
            ClearButton(base: base, size: base * 0.9,
                        help: Localized.text("app.inbox.clear_all"),
                        action: { onClear(tasks) })
        }
        .padding(.horizontal, base * 0.4)
    }
}

/// 通知クリアボタン。台帳レコードを削除する ✕ ボタンとの混同を防ぐため ✔ の記号を使用する。
private struct ClearButton: View {
    let base: CGFloat
    let size: CGFloat
    let help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Image(systemName: "checkmark.circle")
            .font(.system(size: size))
            .foregroundStyle(hovering ? Palette.done : Palette.dim)
            // タップ判定領域を広げて押しやすくする
            .padding(base * 0.2)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // 行全体の onTapGesture との競合を防ぎ、内側のタップを優先させる
            .onTapGesture(perform: action)
            .help(help)
    }
}

/// 新着インボックスのグループ見出し。タスク行の視認性を邪魔しない控えめなスタイルにする。
private struct InboxGroupCaption: View {
    let group: PendingGroup
    let base: CGFloat
    @ObservedObject var avatars: OrgAvatarStore

    var body: some View {
        HStack(spacing: base * 0.25) {
            // リポジトリ単位のまとめ表示時に空の枠が並ぶのを防ぐため、所有者/ホストが判明している場合のみアバターを表示する
            if group.owner != nil || group.host != nil {
                OrgAvatar(owner: group.owner, host: group.host, title: group.title,
                          size: base * 0.8, avatars: avatars)
            }
            Text(group.title)
                .font(.system(size: base * 0.65, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, base * 0.4)
        .padding(.top, base * 0.3)
    }
}

/// 新着タスク行。インデックスとしての視認性を保つためコンパクトに表示する。
private struct InboxRow: View {
    let task: CollectedTask
    let base: CGFloat
    /// 見出しがリポジトリ名を表示していない場合に行内にも表示する
    let showsRepo: Bool
    var onOpen: (CollectedTask) -> Void
    var onClear: (CollectedTask) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: base * 0.35) {
            // 図形チェックマークと文字マークの高さの違いによる上揃えのズレを防ぐため、基準文字の不可視枠の上にオーバーレイ配置する。
            // スクリーンリーダーで空文字が読まれるのを防ぐため accessibilityHidden を付与する
            Text(" ")
                .font(.system(size: base * 0.85, weight: .medium))
                .hidden()
                .accessibilityHidden(true)
                .overlay { mark }
                .frame(width: base * 1.1)
            VStack(alignment: .leading, spacing: base * 0.1) {
                HStack(spacing: base * 0.35) {
                    Text(task.displayName)
                        .font(.system(size: base * 0.85, weight: .medium))
                        .foregroundStyle(Palette.status(task.attentionStatus))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // セッション名よりリポジトリ名の視認性を優先して切り詰めを防ぐ
                    if showsRepo {
                        Text(task.repoName)
                            .font(.system(size: base * 0.7))
                            .foregroundStyle(Palette.dim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                    }
                    Spacer(minLength: base * 0.2)
                    // 経過時間とクリアボタンは領域を共有する。
                    // ホバー時の幅や高さの変動によるガタつきを防ぐため、固定幅の Text 枠の上に overlay で配置し、
                    // ホバー時は文字を非表示（透明）にしてクリアボタンを重ねる。
                    // ボタンのタップ判定が親フレーム外でクリップされないよう、無理な負のパディングは避ける
                    Text(shortAge(task.idleSeconds))
                        .font(.system(size: base * 0.7).monospacedDigit())
                        .foregroundStyle(hovering ? Color.clear : Palette.dim)
                        .overlay(alignment: .trailing) {
                            if hovering {
                                ClearButton(base: base, size: base * 0.8,
                                            help: Localized.text("app.inbox.clear_one"),
                                            action: { onClear(task) })
                            }
                        }
                        .frame(width: base * 1.6, alignment: .trailing)
                        .layoutPriority(1)
                }
                // 承認要求や完了サマリーの内容。緊急度の高い currentRequest（確認待ち）を優先して判定する
                if let request = task.currentRequest {
                    // 先頭（ツール名）と末尾（対象）を残すため中央を省略する
                    Text(request)
                        .font(.system(size: base * 0.7).monospaced())
                        .foregroundStyle(Palette.waiting.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let summary = task.currentSummary {
                    // 完了サマリーのテキスト。文頭の要点を残すため末尾を省略する
                    Text(summary)
                        .font(.system(size: base * 0.7))
                        .foregroundStyle(Palette.dim)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.25)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: base * 0.3)
                .fill(hovering ? Palette.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen(task) }
        .help(task.worktree)
        // 新規追加時のトランジションアニメーション
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// attentionStatus（未対応状態）に応じたアイコンを描画する
    @ViewBuilder
    private var mark: some View {
        switch task.attentionStatus {
        case TaskStatus.waiting:
            Text(TaskStatus.mark(task.attentionStatus))
                .font(.system(size: base * 0.85)).pulsing()
        case TaskStatus.done:
            AnimatedCheckmark(size: base * 0.85, color: Palette.done)
        default:
            Text(TaskStatus.mark(task.attentionStatus)).font(.system(size: base * 0.85))
        }
    }
}

/// サイドバー最下部のレートリミットフッター
private struct RateLimitFooter: View {
    let summaries: [AgentQuotaSummary]
    let base: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1)

            VStack(alignment: .leading, spacing: base * 0.35) {
                ForEach(summaries) { summary in
                    AgentRateLimitRow(summary: summary, base: base)
                }
            }
            .padding(.horizontal, base * 0.5)
            .padding(.vertical, base * 0.4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AgentRateLimitRow: View {
    let summary: AgentQuotaSummary
    let base: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: base * 0.22) {
            HStack(spacing: base * 0.3) {
                agentIcon
                Text(summary.agentDisplayName)
                    .font(.system(size: base * 0.8, weight: .medium))
                    .foregroundStyle(Palette.dim)
            }

            HStack(spacing: base * 0.6) {
                if let five = summary.rateLimits.fiveHour {
                    RateLimitWindowView(label: "5h", window: five, base: base)
                }
                if let week = summary.rateLimits.sevenDay {
                    RateLimitWindowView(label: "7d", window: week, base: base)
                }
            }
        }
    }

    @ViewBuilder
    private var agentIcon: some View {
        AgentIcon(agent: summary.agent, size: base * 0.75)
    }
}

/// エージェント種別のアイコン表示
private struct AgentIcon: View {
    let agent: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(tint)
    }

    private var symbol: String {
        switch agent {
        case AgentKind.antigravity: return "atom"
        // OpenAI に近い六角形グリッドのシンボルを使用する
        case AgentKind.codex: return "circle.hexagongrid.fill"
        default: return "terminal.fill"
        }
    }

    private var tint: Color {
        switch agent {
        case AgentKind.antigravity: return Palette.antigravity
        case AgentKind.codex: return Palette.codex
        default: return Palette.claude
        }
    }
}

private struct RateLimitWindowView: View {
    let label: String
    let window: RateLimitWindow
    let base: CGFloat

    private var barWidth: CGFloat { base * 1.8 }
    private var barHeight: CGFloat { max(3.5, base * 0.22) }

    var body: some View {
        HStack(spacing: base * 0.22) {
            Text(label)
                .font(.system(size: base * 0.78, weight: .semibold).monospaced())
                .foregroundStyle(Palette.dim)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.gray.opacity(0.25))
                Capsule()
                    .fill(Palette.context(window.usedPercent))
                    .frame(width: max(0, min(barWidth, barWidth * CGFloat(window.usedPercent) / 100)))
            }
            .frame(width: barWidth, height: barHeight)

            Text("\(window.usedPercent)%")
                .font(.system(size: base * 0.78).monospacedDigit())
                .foregroundStyle(Palette.context(window.usedPercent))

            if let resetText = formatResetTime(window.resetsAt) {
                Text(resetText)
                    .font(.system(size: base * 0.72).monospacedDigit())
                    .foregroundStyle(Palette.dim)
            }
        }
    }

    private func formatResetTime(_ epoch: Int?) -> String? {
        guard let epoch, epoch > 0 else { return nil }
        let now = Date().timeIntervalSince1970
        guard Double(epoch) - now > 0 else { return nil }

        let resetDate = Date(timeIntervalSince1970: Double(epoch))
        let formatter = Calendar.current.isDateInToday(resetDate)
            ? ResetTimeFormat.timeOnly
            : ResetTimeFormat.dateAndTime
        return formatter.string(from: resetDate)
    }
}

/// レートリミット解除時刻フォーマッタのキャッシュ（DateFormatter 生成コストの回避）
private enum ResetTimeFormat {
    static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static let dateAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}
