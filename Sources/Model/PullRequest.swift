import Foundation

/// ブランチに紐づく Pull Request 1件のうち、一覧に出すのに要るものだけ。
///
/// 名前を gh の `--json` のフィールド名にそのまま合わせてある。
/// 詰め替えの表を挟むと、足したいものが増えるたびに2か所直すことになる。
public struct PullRequestRef: Codable, Equatable, Sendable {
    public var number: Int
    /// **gh が返した URL をそのまま持つ。自分で組み立てない。**
    /// 組み立て方を写すと GitHub Enterprise のホストで嘘をつくし、
    /// 写した時点で gh 側の答えと食い違いうる
    public var url: String
    /// "OPEN" / "MERGED" / "CLOSED"。**何色で出すかはここでは決めない**
    /// (CLI は Terminal、アプリは Palette が持つ)
    public var state: String
    public var isDraft: Bool
    /// PR の見出し。番号だけでは何の PR か分からないので、
    /// 一覧では出さずにツールチップで見せる
    public var title: String

    public init(number: Int, url: String, state: String, isDraft: Bool, title: String) {
        self.number = number
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.title = title
    }
}

/// PR を引いた結果。
///
/// **「無い」と「聞けなかった」を必ず分ける。** どちらも画面には何も出ないが、
/// 覚えてよいのは前者だけ。混ぜると、gh が一時的に使えないだけの状態が
/// 「この branch に PR は無い」として焼き付き、期限が切れるまで番号が出なくなる
/// (前身の taskhub で、PATH に gh が居ないだけの環境で番号が消え続けた)。
public enum PullRequestLookup: Equatable, Sendable {
    case found(PullRequestRef)
    /// この branch に PR は無い。gh はちゃんと答えた
    case absent
    /// 聞けなかった。gh が無い・認証が切れている・通信できない・相手が GitHub ではない
    case unavailable
}

/// PR の状態の語彙。`TaskStatus` と同じ線引きで、
/// 「どんな状態があり、何と呼ぶか」までをここが持つ。
public enum PullRequestState {
    public static let open = "OPEN"
    public static let merged = "MERGED"
    public static let closed = "CLOSED"
}
