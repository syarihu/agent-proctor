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
    var onOpen: (CollectedTask) -> Void

    /// 文字の大きさはここだけで決める。余白も記号もこれに追従する。
    /// メニューバーから変えられる (Appearance)
    private var base: CGFloat { appearance.fontSize }

    var body: some View {
        ScrollView {
            if store.tasks.isEmpty {
                Text("動いているエージェントはいません")
                    .font(.system(size: base * 0.9))
                    .foregroundStyle(Palette.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, base * 0.4)
                    .padding(.vertical, base * 0.6)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.repo) { group in
                        // 1つしかないなら見出しは情報を持たない。縦を空けるだけなので出さない
                        if groups.count > 1 {
                            Text(group.name)
                                .font(.system(size: base * 0.75, weight: .semibold))
                                .foregroundStyle(Palette.dim)
                                .lineLimit(1)
                                .padding(.horizontal, base * 0.4)
                                .padding(.top, base * 0.6)
                                .padding(.bottom, base * 0.1)
                        }
                        ForEach(group.tasks) { task in
                            TaskRow(task: task, base: base, onOpen: onOpen)
                                .padding(.leading, groups.count > 1 ? base : 0)
                        }
                    }
                }
            }
        }
        // 余白はすべて文字の大きさに対する比で持つ。
        // そうしないと大きくしたときだけ窮屈になる
        .padding(base * 0.3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private struct Group {
        var repo: String
        var name: String
        var tasks: [CollectedTask]
    }

    /// プロジェクトごとにまとめる。動きがあったものを上に置く。
    /// 名前順だと、今まさに動いているプロジェクトが下に埋もれて気づけない
    private var groups: [Group] {
        var order: [String] = []
        var box: [String: Group] = [:]
        for task in store.tasks {
            if box[task.repo] == nil {
                order.append(task.repo)
                box[task.repo] = Group(repo: task.repo, name: task.repoName, tasks: [])
            }
            box[task.repo]?.tasks.append(task)
        }
        return order.compactMap { box[$0] }
            .sorted { recency($0) < recency($1) }
    }

    private func recency(_ group: Group) -> Int {
        group.tasks.map(\.idleSeconds).min() ?? .max
    }
}

private struct TaskRow: View {
    let task: CollectedTask
    let base: CGFloat
    var onOpen: (CollectedTask) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: base * 0.4) {
            mark
                .frame(width: base * 1.3, alignment: .center)
                .padding(.top, base * 0.1)

            VStack(alignment: .leading, spacing: base * 0.15) {
                // エージェント名とアイコン
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
                        Text("(context: \(percent)%)")
                            .font(.system(size: base * 0.7).monospacedDigit())
                            .foregroundStyle(Palette.context(percent))
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: base * 0.5) {
                    Text(task.displayName)
                        .font(.system(size: base, weight: .semibold))
                        // 待たせているものは目に留まってほしいので少し強く出す
                        .foregroundStyle(task.status == TaskStatus.waiting ? Palette.waiting : Palette.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(alignment: .firstTextBaseline, spacing: base * 0.6) {
                    Text("\(task.branch) · 経過: \(shortAge(task.idleSeconds))")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if task.subagents > 0 {
                        Text("🤖\(task.subagents)")
                            .foregroundStyle(Palette.agents)
                            .pulsing()
                            .layoutPriority(1)
                    }
                    Spacer(minLength: base * 0.25)
                    diff.layoutPriority(1)
                }
                .font(.system(size: base * 0.8))
                .foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, base * 0.4)
        // 行がぎゅうぎゅうだと状態を追いにくい
        .padding(.vertical, base * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering ? Palette.hover : .clear,
                    in: RoundedRectangle(cornerRadius: base * 0.3))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen(task) }
        .help(task.worktree)
    }

    @ViewBuilder
    private var agentIcon: some View {
        if task.resolvedAgent == "agy" {
            Image(systemName: "atom")
                .font(.system(size: base * 0.7))
                .foregroundStyle(Palette.antigravity)
        } else {
            Image(systemName: "terminal.fill")
                .font(.system(size: base * 0.7))
                .foregroundStyle(Palette.claude)
        }
    }

    /// 実行中は回っているものを出す。動きがあるだけで「止まっていない」ことが一目で分かる。
    /// 確認待ちはこちらの操作を待たせている状態なので、ゆっくり明滅させる
    @ViewBuilder
    private var mark: some View {
        switch task.status {
        case TaskStatus.running:
            Spinner(size: base)
        case TaskStatus.waiting:
            Text(TaskStatus.mark(task.status)).font(.system(size: base)).pulsing()
        default:
            Text(TaskStatus.mark(task.status)).font(.system(size: base))
        }
    }

    @ViewBuilder
    private var diff: some View {
        HStack(spacing: 4) {
            if task.diff.added > 0 {
                Text("+\(task.diff.added)").foregroundStyle(Palette.added)
            }
            if task.diff.removed > 0 {
                Text("-\(task.diff.removed)").foregroundStyle(Palette.removed)
            }
            if task.diff.untracked > 0 {
                Text("?\(task.diff.untracked)").foregroundStyle(Palette.untracked)
            }
        }
        .font(.system(size: base * 0.8).monospacedDigit())
    }

    private func shortAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
}

/// 回っているリング。実行中の印。
///
/// macOS 標準の ProgressView は細く薄いので、小さな行の中では何が起きているのか
/// 分かりにくい。元の iTerm2 パネルが CSS で描いていたリングをそのまま起こす。
/// 薄い輪を下敷きにして、その一部だけ色を付けて回す形。
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
    static let waiting = Color(red: 1.0, green: 0.655, blue: 0.149)     // #ffa726
    static let agents = Color(red: 0.671, green: 0.533, blue: 0.941)    // #ab88f0
    static let added = Color(red: 0.298, green: 0.686, blue: 0.314)     // #4caf50
    static let removed = Color(red: 0.937, green: 0.325, blue: 0.314)   // #ef5350
    static let untracked = Color(red: 0.161, green: 0.714, blue: 0.965) // #29b6f6
    static let spinner = Color(red: 0.310, green: 0.765, blue: 0.969)   // #4fc3f7
    static let claude = Color(red: 0.878, green: 0.478, blue: 0.345)       // #e07a58 (テラコッタ)
    static let antigravity = Color(red: 0.353, green: 0.647, blue: 0.980)  // #5aa5fa (ブルー)

    /// 残りが少なくなってきたら色で知らせる (statusline と同じ考え方)
    static func context(_ percent: Int) -> Color {
        if percent >= 80 { return removed }
        if percent >= 50 { return Color(red: 1.0, green: 0.718, blue: 0.302) } // #ffb74d
        return dim
    }
}
