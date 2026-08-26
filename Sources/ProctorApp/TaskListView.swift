import SwiftUI
import ProctorKit

/// サイドバーに出す一覧。
///
/// 見せているのは「タブを見ても分からない情報」に絞っている。
/// セッション名・コンテキスト使用率・サブエージェントの数、そして
/// 最後に状態が動いてからの経過時間。実行中のまま経過が長ければ、
/// 考え込んでいるのか止まっているのかの手がかりになる。
struct TaskListView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var appearance: Appearance
    @ObservedObject var folding: GroupFolding
    @ObservedObject var avatars: OrgAvatarStore
    var onOpen: (CollectedTask) -> Void
    var onClose: (CollectedTask) -> Void
    /// セッションの乗っていない worktree を押したとき。
    /// 戻る先のタブが無いので、そこへ移動した新しいタブを開く
    var onOpenWorktree: (CollectedWorktree) -> Void

    /// 文字の大きさはここだけで決める。余白も記号もこれに追従する。
    /// メニューバーから変えられる (Appearance)
    private var base: CGFloat { appearance.fontSize }

    var body: some View {
        // **まとめ直しは body 1回につき1度だけ。** 計算プロパティのままだと
        // ForEach と animation の value の両方から読まれ、同じ組み直しが
        // 2度3度走る。台帳はツールが動くたびに変わるので、そのたびに掛かる
        let byOrg = appearance.resolvedGrouping == .organization
        let orgs = byOrg ? orgGroups : []
        let repos = byOrg ? [] : repoGroups
        let limits = rateLimitSummaries
        return ZStack {
            // 背景のアンビエントグロー（確認待ちや実行中の状態に応じたやわらかな環境光）
            ambientGlow

            VStack(spacing: 0) {
                ScrollView {
                    // **worktree だけが残っている状態を「何も無い」と言わない。**
                    // セッションが全部終わったあとこそ、残った作業場を見たい
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
                                   value: orderKey(orgs: orgs, repos: repos))
                    }
                }
                .padding(base * 0.3)

                if !limits.isEmpty {
                    RateLimitFooter(summaries: limits, base: base)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var rateLimitSummaries: [AgentQuotaSummary] {
        store.rateLimitSummaries
    }

    /// リポジトリの見出しと、その下の行。**まとめ方が1段でも2段でも同じものを使う。**
    /// 段ごとに書き分けると、折りたたみも内訳も2通り面倒を見ることになる。
    ///
    /// - Parameter indent: 左に空ける分。Organization の下にぶら下がるときだけ入る。
    ///   ぶら下がっているときは上の余白も詰める。**組織どうしの間より、
    ///   組織とその中身の間のほうが空いていると、どちらの子なのか分からなくなる**
    @ViewBuilder
    private func repoSection(_ group: RepoGroup, indent: CGFloat) -> some View {
        // 1つしかないときも出す。畳む取っ手はここにしかないし、
        // どのリポジトリを見ているのかは1つでも知りたい
        RepoHeader(
            name: group.name,
            repo: group.id,
            base: base,
            topSpacing: indent > 0 ? base * 0.15 : base * 0.3,
            collapsed: folding.isCollapsed(group.id),
            tally: TaskStatus.counts(displayStatuses: group.tasks.map(\.displayStatus)),
            onToggle: { toggle(group.id) })
            .padding(.leading, indent)
        if !folding.isCollapsed(group.id) {
            ForEach(group.tasks) { task in
                TaskRow(task: task, base: base,
                        isCurrent: isCurrent(task),
                        onOpen: onOpen, onClose: onClose)
                    .padding(.leading, base + indent)
            }
            if !group.worktrees.isEmpty {
                // 鍵に "wt:" を付けるのは、リポジトリ本体の鍵 (絶対パス) と
                // 同じ文字列にならないようにするため
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

    /// いま iTerm2 で開いているタブかどうか。
    /// 台帳を持たないセッション (itermSession が無い) を巻き込まないよう、
    /// 空同士が一致してしまう組み合わせは弾く
    private func isCurrent(_ task: CollectedTask) -> Bool {
        guard let focused = store.focusedSession, !focused.isEmpty else { return false }
        return task.itermSession == focused
    }

    /// 折りたたみの開け閉め。畳むと行が消えるので、動かして見せないと
    /// 何が起きたのか分からない (押した場所の下が急に詰まる)
    private func toggle(_ group: String) {
        withAnimation(.easeOut(duration: 0.18)) { folding.toggle(group) }
    }

    /// 既定で畳んであるもの (worktree の一覧) の開け閉め
    private func toggleExpanded(_ group: String) {
        withAnimation(.easeOut(duration: 0.18)) { folding.toggleExpanded(group) }
    }

    /// 並びが変わったことを animation に伝える鍵。
    ///
    /// **いま実際に描いている並びから作る。** 片方のまとめ方だけを見て作ると、
    /// 見出しの順が入れ替わっても鍵が変わらないことがあり、その回だけ行が
    /// 瞬間移動する
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
        TaskGrouping.byRepository(store.tasks, worktrees: store.worktrees)
    }

    private var orgGroups: [OrgGroup] {
        TaskGrouping.byOrganization(
            store.tasks, worktrees: store.worktrees,
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

/// Organization ごとの見出し。押すとその下のリポジトリごと畳む。
///
/// リポジトリの見出し (`RepoHeader`) より一段強く出す。**同じ見え方にすると、
/// どちらが親でどちらが子か分からなくなる。** 差を付けているのは3つ ——
/// アイコンが付くこと、文字が濃いこと、上の余白が広いこと。
/// 大きさで差を付けていないのは、主役であるセッション名より大きい見出しを
/// 2段重ねると、読む順が上から順に入れ替わってしまうため。
private struct OrgHeader: View {
    let group: OrgGroup
    let base: CGFloat
    @ObservedObject var avatars: OrgAvatarStore
    let collapsed: Bool
    /// 中にいるセッション全部の内訳。畳んでいるときだけ出す
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

/// Organization のアイコン。
///
/// 取れていないあいだ、そして取れなかった相手には頭文字を描く。**枠ごと
/// 消さないのは、あとから絵が入ったときに見出しの文字が横へずれるため。**
/// 場所は先に取っておいて、中身だけ差し替える。
private struct OrgAvatar: View {
    /// GitHub の login 名。持ち主が分からないまとまりでは nil
    let owner: String?
    let host: String?
    /// 頭文字を描くもと。持ち主が分からないときの見出しにも頭文字は要る
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
        // 真円ではなく角丸にしているのは GitHub の見せ方に合わせるため。
        // 組織のアイコンは四角い図案が多く、丸で抜くと角が落ちる
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        // 取りに行くのは描くときではなくここ。body の中で store を触ると、
        // 描いている最中に状態が変わることになる
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

/// プロジェクトごとの見出し。押すとその下を畳む。
///
/// 畳んでいる間は中身の状態を数で出す。**畳んだせいで確認待ちに気づけない、
/// を作らないため。**開いているときは行そのものが出ているので、
/// 同じ数を見出しにも書くと同じことを二度言うことになる。
///
/// ここでは確認済み (✔) も数える。メニューバーの数字と違って、この数は
/// 「中に何件あるか」でもある。見終わったものを外すと、畳んだ先に何も
/// 入っていないように見えてしまう。
private struct RepoHeader: View {
    let name: String
    /// リポジトリのパス。ツールチップに出すのと、鍵として渡すのに使う
    let repo: String
    let base: CGFloat
    /// 前のまとまりとの間に空ける分。Organization の下では詰める
    let topSpacing: CGFloat
    let collapsed: Bool
    /// 畳んでいるときに出す内訳。確認済みも含めて渡してもらう
    let tally: [(status: String, count: Int)]
    var onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: base * 0.3) {
            // 三角は回して向きを変える。開閉のたびに別の記号に差し替えると、
            // 同じ場所で形が飛んで見える
            Image(systemName: "chevron.right")
                .font(.system(size: base * 0.7, weight: .semibold))
                .foregroundStyle(Palette.dim)
                .rotationEffect(.degrees(collapsed ? 0 : 90))
                .frame(width: base * 0.8)

            // セッション名 (base) より一段だけ小さくする。見出しなので
            // 目に入る大きさは要るが、主役の名前より大きいと読む順が入れ替わる
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
        .help(repo)
        // グループを区切る余白。下地とタップ範囲の外に出しておく。
        // 内側に入れると、上だけ広く光って押せる範囲も上下でずれる
        .padding(.top, topSpacing)
    }
}

/// 「他に N worktree」の1行。押すと下に一覧が開く。
///
/// セッションの行と見た目を分けている。**同じ強さで出すと、動いているものと
/// 残っているだけのものが並んで見えて、どちらに手を付けるべきか分からなくなる。**
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

            // 片付けられるものがあるときだけ数を添える。**0 を出さない。**
            // 何も片付けられない日に「0」が並ぶと、見る意味の無い行になる
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

/// セッションが乗っていない worktree の1行。押すとその場所が開く
private struct WorktreeRow: View {
    let worktree: CollectedWorktree
    let base: CGFloat
    var onOpen: (CollectedWorktree) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: base * 0.4) {
            // セッションの印 (状態) とは別の記号にする。
            // 状態を持たない場所なので、状態の色を借りると誤解になる
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
                    } else if worktree.merged {
                        Text(Localized.text("app.worktree.merged"))
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
    var onOpen: (CollectedTask) -> Void
    var onClose: (CollectedTask) -> Void

    @State private var hovering = false
    @State private var diving = false
    /// 閉じるボタンの上にいるか。行のホバーとは別に持つ (色を変えるため)
    @State private var closeHovering = false

    /// 終わったあと、そのタブを見たもの
    private var isSeen: Bool { task.displayStatus == TaskStatus.seen }

    var body: some View {
        HStack(alignment: .top, spacing: base * 0.4) {
            mark
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

                // ブランチ・経過時間・サブエージェント・diff
                HStack(alignment: .firstTextBaseline, spacing: base * 0.6) {
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

                // いま触っているツール。動いているあいだだけ出る (currentActivity)。
                // ツールのたびに差し替わるので、文字にはアニメーションを付けない
                // (1手ごとに動くと目が休まらない)
                if let activity = task.currentActivity {
                    Text(activity)
                        .font(.system(size: base * 0.75).monospaced())
                        .foregroundStyle(Palette.activity)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 走っているサブエージェント。数 (🤖2) だけでは何をさせているか
                // 分からないので、1体ずつぶら下げる
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
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 重ねて置く。行の中に並べると、出入りのたびに幅が変わって文字がずれる
        .overlay(alignment: .topTrailing) { closeButton }
        // 見終わったものは役目を終えたので引いて背景に馴染ませる。消さずに残すのは、
        // 何をやったかを後から辿れるようにするため。
        // ただし今開いているタブは、引いた分を打ち消して居場所が埋もれないようにする
        .opacity(isSeen && !isCurrent ? 0.45 : 1)
        .background(
            ZStack {
                // いま見ているタブ。状態の色とぶつからないよう、
                // 薄い下地と左の帯で示す
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
                    // iTerm2 へダイブする瞬間の光のフラッシュ
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
    }

    /// ホバー中だけ出る「一覧から外す」ボタン。
    ///
    /// 押しても消えるのは台帳の記録だけで、worktree には触らない。
    /// 常に出しておくと、ただでさえ情報の多い行がさらに読みにくくなるので隠しておく。
    ///
    /// クリックは行と同じ onTapGesture で受ける。内側のタップが優先されるので
    /// 行の「開く」は動かない。サイドバーは nonactivatingPanel で、この方式なら
    /// 手前に出ていなくても1回目のクリックから効く
    @ViewBuilder
    private var closeButton: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: base * 0.85))
            .foregroundStyle(closeHovering ? Palette.removed : Palette.dim)
            // 記号そのものは小さいので、当たり判定だけ広げて押しやすくする
            .padding(base * 0.3)
            .contentShape(Rectangle())
            .onHover { closeHovering = $0 }
            .onTapGesture { onClose(task) }
            .help(Localized.text("app.row.close_help"))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    /// 待たせているものは目に留まってほしいので少し強く出す。
    /// 終わったのにまだ見ていないものも色を残し、見たら普通の色に戻す
    /// (色が付いている = まだ手を付けていない、で読めるようにする)
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

    /// 実行中は回っているリング、確認待ちはゆっくり明滅、完了時はシュッと描かれるチェックマーク。
    /// 見終わったもの (確認済み) は静かな ✔ に置き換える
    @ViewBuilder
    private var mark: some View {
        switch task.displayStatus {
        case TaskStatus.running:
            Spinner(size: base)
        case TaskStatus.waiting:
            Text(TaskStatus.mark(task.displayStatus)).font(.system(size: base)).pulsing()
        case TaskStatus.done:
            // まだ見ていない完了。タイトルと同じ色にして、印と名前で色がちぐはぐにならないようにする
            AnimatedCheckmark(size: base, color: Palette.done)
        default:
            Text(TaskStatus.mark(task.displayStatus)).font(.system(size: base))
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
        }
        .font(.system(size: base * 0.8).monospacedDigit())
    }

}

/// 親の下にぶら下がるサブエージェント1体。
///
/// 2行に分けているのは、**何をさせているか**と**いま何をしているか**が
/// 別の情報だから。前者は最後まで変わらず、後者はツールのたびに入れ替わる。
/// 1行に混ぜると、変わらないはずの部分まで動いて見えて落ち着かない。
private struct SubagentRow: View {
    let sub: CollectedSubagent
    let base: CGFloat
    /// 最後の1体だけ枝の形を変える。何体で終わりかが目で分かる
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
                    // 手元がまだ分からない子もいる (起動した直後など)。
                    // 行の高さが揺れないよう、そのときも経過だけは出す
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

/// 経過時間の短い表記。親の行も子の行も同じ読み方にしたいので、外に出してある
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

/// 差分が増えたときに「ポンッ」と小さく弾けて光るバッジ
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

/// 完了時にシュッと一筆書きで描かれるチェックマーク
private struct AnimatedCheckmark: View {
    let size: CGFloat
    /// 既定は控えめな色。まだ見ていない完了だけ、呼ぶ側が色を渡して目立たせる
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

/// 回っているリング。実行中の印。
private struct Spinner: View {
    let size: CGFloat
    @State private var spinning = false

    /// 線の太さは直径に対する比で持つ。文字を大きくしても細くならない
    private var lineWidth: CGFloat { max(1.5, size * 0.16) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.25), lineWidth: lineWidth)
            Circle()
                // 4分の1だけ描いて回す。全周だと止まって見える
                .trim(from: 0, to: 0.25)
                .stroke(Palette.spinner,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(.linear(duration: 0.8).repeatForever(autoreverses: false),
                           value: spinning)
        }
        // 線が枠からはみ出さないよう、太さの分だけ内側に描く
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .onAppear { spinning = true }
    }
}

/// ゆっくり明滅させる。確認待ちとサブエージェントの「まだ動いている」印に使う。
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

/// 色は元の iTerm2 パネルの CSS から持ってきている。
/// ライト/ダークで変えるものだけ環境に追従させる
enum Palette {
    static let fg = Color.primary
    static let dim = Color.secondary
    static let hover = Color.gray.opacity(0.18)
    /// いま開いているタブの下地。帯 (spinner の色) と合わせて居場所を示す
    static let current = Color.gray.opacity(0.13)
    static let waiting = Color(red: 1.0, green: 0.655, blue: 0.149)     // #ffa726
    /// 終わったのにまだ見ていないもの。印 (✅) と揃えて緑にする
    static let done = Color(red: 0.400, green: 0.733, blue: 0.416)      // #66bb6a
    static let agents = Color(red: 0.671, green: 0.533, blue: 0.941)    // #ab88f0
    static let added = Color(red: 0.298, green: 0.686, blue: 0.314)     // #4caf50
    static let removed = Color(red: 0.937, green: 0.325, blue: 0.314)   // #ef5350
    static let untracked = Color(red: 0.161, green: 0.714, blue: 0.965) // #29b6f6
    static let spinner = Color(red: 0.310, green: 0.765, blue: 0.969)   // #4fc3f7
    /// いま触っているツールの行。主役はセッション名なので、
    /// 読めるが目を引かない程度に落とす
    static let activity = Color.secondary.opacity(0.85)
    static let claude = Color(red: 0.878, green: 0.478, blue: 0.345)       // #e07a58 (テラコッタ)
    static let antigravity = Color(red: 0.353, green: 0.647, blue: 0.980)  // #5aa5fa (ブルー)
    static let codex = Color(red: 0.063, green: 0.639, blue: 0.498)        // #10a37f (グリーン)

    /// 状態そのものを表す色。畳んだ見出しの内訳のように、
    /// 印と数だけで状態を見せる場所で使う。
    ///
    /// 行のタイトル (TaskRow.titleColor) とは別に持つ。あちらは読ませるのが仕事なので
    /// 実行中まで色を付けず、待たせているものだけを目立たせている
    static func status(_ status: String) -> Color {
        switch status {
        case TaskStatus.waiting: return waiting
        case TaskStatus.running: return spinner
        case TaskStatus.done: return done
        // 失敗は見たあとも失敗のまま残る = まだ片付いていない。
        // 畳んで数だけになったときこそ、脇役の色にしてはいけない
        case TaskStatus.failed: return removed
        default: return dim
        }
    }

    /// 残りが少なくなってきたら色で知らせる (statusline と同じ考え方)
    static func context(_ percent: Int) -> Color {
        if percent >= 80 { return removed }
        if percent >= 50 { return Color(red: 1.0, green: 0.718, blue: 0.302) } // #ffb74d
        return dim
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

/// どのエージェントが動かしているかの印。
///
/// 行の頭と、レートリミットの見出しの2か所に出る。**同じ絵柄でなければ
/// 別のものに見える**ので、片方だけ足せる形にはしない。
/// 絵柄と色は AgentKind の値で引く (名前と並び順は Kit 側が持っている)
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
        // OpenAI の印は六角の結び目。SF Symbols で一番近いのがこれ
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

/// レートリミットの明ける時刻に使う書式。
///
/// `DateFormatter` は作るのが高く、ここは一覧の描画のたびに行の数だけ通る。
/// 使うのは文字列に直すことだけなので、持ち回して困らない。
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
