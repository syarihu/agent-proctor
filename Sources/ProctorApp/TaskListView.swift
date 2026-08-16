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
        ZStack {
            // 背景のアンビエントグロー（確認待ちや実行中の状態に応じたやわらかな環境光）
            ambientGlow

            ScrollView {
                if store.tasks.isEmpty {
                    Text("動いているエージェントはいません")
                        .font(.system(size: base * 0.9))
                        .foregroundStyle(Palette.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, base * 0.4)
                        .padding(.vertical, base * 0.6)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
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
                    .animation(.spring(response: 0.35, dampingFraction: 0.78), value: taskOrderKey)
                }
            }
            .padding(base * 0.3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var taskOrderKey: String {
        groups.map { "\($0.repo):" + $0.tasks.map(\.id).joined(separator: ",") }.joined(separator: "|")
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

private struct TaskRow: View {
    let task: CollectedTask
    let base: CGFloat
    var onOpen: (CollectedTask) -> Void

    @State private var hovering = false
    @State private var diving = false

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
                        // 待たせているものは目に留まってほしいので少し強く出す
                        .foregroundStyle(task.status == TaskStatus.waiting ? Palette.waiting : Palette.fg)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // ブランチ・経過時間・サブエージェント・diff
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
                    diffView.layoutPriority(1)
                }
                .font(.system(size: base * 0.8))
                .foregroundStyle(Palette.dim)
            }
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
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

    /// 実行中は回っているリング、確認待ちはゆっくり明滅、完了時はシュッと描かれるチェックマーク
    @ViewBuilder
    private var mark: some View {
        switch task.status {
        case TaskStatus.running:
            Spinner(size: base)
        case TaskStatus.waiting:
            Text(TaskStatus.mark(task.status)).font(.system(size: base)).pulsing()
        case TaskStatus.done:
            AnimatedCheckmark(size: base)
        default:
            Text(TaskStatus.mark(task.status)).font(.system(size: base))
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

    private func shortAge(_ seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86400)d"
    }
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
    @State private var progress: CGFloat = 0

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(Palette.dim, style: StrokeStyle(lineWidth: max(1.5, size * 0.14), lineCap: .round, lineJoin: .round))
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
