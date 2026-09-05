import Foundation

/// ブランチに紐づく Pull Request 1件のうち、一覧に出すのに要るものだけ。
///
/// 名前を gh の `--json` のフィールド名にそのまま合わせてある。
/// 詰め替えの表を挟むと、足したいものが増えるたびに2か所直すことになる。
public struct PullRequestRef: Codable, Equatable, Sendable {
    public var number: Int
    /// gh が返した URL をそのまま保持する。
    /// 独自に URL を組み立てると GitHub Enterprise 等で不整合を起こすため。
    public var url: String
    /// "OPEN" / "MERGED" / "CLOSED"。配色の責務は View 側が担う。
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

/// PR を取得した結果。
///
/// PR が存在しないことと、通信エラー等で取得できなかった状態を区別する。
/// 取得失敗を非存在としてキャッシュしてしまうと、一時的な障害時に存在しないと誤認され続けるため。
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
