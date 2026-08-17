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
                                TaskRow(task: task, base: base,
                                        isCurrent: isCurrent(task), onOpen: onOpen)
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

    /// いま iTerm2 で開いているタブかどうか。
    /// 台帳を持たないセッション (itermSession が無い) を巻き込まないよう、
    /// 空同士が一致してしまう組み合わせは弾く
    private func isCurrent(_ task: CollectedTask) -> Bool {
        guard let focused = store.focusedSession, !focused.isEmpty else { return false }
        return task.itermSession == focused
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
    /// いま iTerm2 で開いているタブ
    let isCurrent: Bool
    var onOpen: (CollectedTask) -> Void

    @State private var hovering = false
    @State private var diving = false

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
            }
        }
        .padding(.horizontal, base * 0.4)
        .padding(.vertical, base * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// 残りが少なくなってきたら色で知らせる (statusline と同じ考え方)
    static func context(_ percent: Int) -> Color {
        if percent >= 80 { return removed }
        if percent >= 50 { return Color(red: 1.0, green: 0.718, blue: 0.302) } // #ffb74d
        return dim
    }
}
