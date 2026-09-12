import AppKit
import Foundation
import Model
import SpriteKit

// MARK: - 見取り図モデル

/// 机1つ。台帳の1セッションに対応する
public struct DeskSeat: Equatable {
    /// `CollectedTask.id`。クリックで開く相手
    public let id: String
    public let name: String
    /// `CollectedTask.displayStatus`
    public let status: String
    /// 人の手が要るか (`TaskStatus.needsPerson`)。カメラがここを最優先で映す
    public let needsPerson: Bool
    public let contextPercent: Int?
    /// 走っているサブエージェントの数。
    /// `agent_id` を送ってこないエージェントでは中身が空でも数だけ入る
    public let subagents: Int
    /// 中身が分かるサブエージェント。分かるなら1体ずつ仕草を付けられる
    public let helpers: [DeskHelper]
    /// いま触っているツール ("Edit: TaskStore.swift" など)。動いている間だけ入る。
    /// 何をしているかで仕草を変えるために使う
    public let activity: String?
    /// 現在 iTerm2 で人間が見ているタブかどうか
    public let isCurrent: Bool
    /// 対応するタブ番号（⌘1 など）
    public let tabNumber: Int?
    /// エージェントのモデル名（"Opus 5"、"Gemini 3.8 Flash" など）
    public let model: String?
    /// エージェント表示名（モデル名がない場合のフォールバック等に使用）
    public let agent: String?

    public init(id: String, name: String, status: String, needsPerson: Bool,
                contextPercent: Int?, subagents: Int, helpers: [DeskHelper],
                activity: String?, isCurrent: Bool, tabNumber: Int?,
                model: String? = nil, agent: String? = nil) {
        self.id = id
        self.name = name
        self.status = status
        self.needsPerson = needsPerson
        self.contextPercent = contextPercent
        self.subagents = subagents
        self.helpers = helpers
        self.activity = activity
        self.isCurrent = isCurrent
        self.tabNumber = tabNumber
        self.model = model
        self.agent = agent
    }

    /// 卓上ネームプレートに表示する名称
    public var nameplateText: String? {
        if let model, !model.isEmpty {
            return Self.formatModelName(model)
        }
        return agent
    }

    /// モデル名をネームプレート向けに整形する
    public static func formatModelName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 日付サフィックス（例: -20250219）を取り除く
        if let range = text.range(of: #"-\d{8}$"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        let lower = text.lowercased()
        switch lower {
        case "claude-3-7-sonnet": return "Claude 3.7 Sonnet"
        case "claude-3-5-sonnet": return "Claude 3.5 Sonnet"
        case "claude-3-5-haiku": return "Claude 3.5 Haiku"
        case "claude-3-opus": return "Claude 3 Opus"
        case "sonnet": return "Sonnet"
        case "opus": return "Opus"
        case "haiku": return "Haiku"
        case "gemini-2.5-pro": return "Gemini 2.5 Pro"
        case "gemini-2.5-flash": return "Gemini 2.5 Flash"
        case "gemini-1.5-pro": return "Gemini 1.5 Pro"
        case "gemini-1.5-flash": return "Gemini 1.5 Flash"
        case "gpt-4o": return "GPT-4o"
        case "gpt-4o-mini": return "GPT-4o mini"
        case "o1": return "o1"
        case "o1-mini": return "o1-mini"
        case "o1-preview": return "o1-preview"
        case "o3-mini": return "o3-mini"
        default:
            return text
        }
    }
}

/// 机まわりの手伝い1人。台帳のサブエージェント1体に対応する
public struct DeskHelper: Equatable {
    public let id: String
    /// エージェント種別 ("Explore" など)
    public let name: String
    /// いま触っているツール。親と同じ形式なので、同じ判定で仕草を決められる
    public let activity: String?

    public init(id: String, name: String, activity: String?) {
        self.id = id
        self.name = name
        self.activity = activity
    }
}

/// 机の人の仕草。`activity` の頭 ("Edit: …" の Edit) から決める。
///
/// ツール名をそのまま出す代わりに、体の動きで言う。
/// 文字は小さくて読めないが、動きの違いは離れていても分かる
public enum DeskGesture {
    /// 書いている (Edit / Write)
    case typing
    /// 読んでいる・探している (Read / Grep / Glob)
    case reading
    /// コマンドを回している (Bash)
    case terminal
    /// 返事を待っている (Task / WebFetch など、自分では手を動かしていないもの)
    case thinking

    /// ツール名から仕草を決める。
    ///
    /// 知らないツールは書いていることにする。一番多いのがそれで、
    /// 外したときの見え方も一番おとなしい
    public static func from(activity: String?) -> DeskGesture {
        let tool = activity?.split(separator: ":").first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        switch tool {
        case "Read", "Grep", "Glob", "LS", "NotebookRead", "Explore",
             "view_file", "grep_search", "find_by_name", "list_dir", "search_web", "read_url_content", "WebSearch":
            return .reading
        case "Bash", "BashOutput", "KillShell", "KillBash", "run_command":
            return .terminal
        case "Task", "Agent", "WebFetch", "SendMessage", "invoke_subagent":
            return .thinking
        default:
            return .typing
        }
    }
}

/// リポジトリ1つ分の島。見出しの机 (hub) と、その下に並ぶセッションの机。
///
/// adjutant を繋いだら hub は本物の hub セッションになる。
/// いまはリポジトリの名札で、座っている人はいない
public struct DeskIsland: Equatable {
    public let repo: String
    public let seats: [DeskSeat]
    public let origin: RepoOrigin?

    public init(repo: String, seats: [DeskSeat], origin: RepoOrigin? = nil) {
        self.repo = repo
        self.seats = seats
        self.origin = origin
    }

    /// Organization の識別キー（例: "github.com/syarihu"）
    public var organizationKey: String {
        origin?.groupKey ?? ""
    }

    /// Organization の表示名（例: "syarihu"）
    public var organizationName: String? {
        origin?.owner
    }
}

/// 画面外からの呼び出し吹き出しの向き
enum CallingDirection: Equatable {
    case top
    case bottom
    case left
    case right
}

/// 画面外の要確認吹き出しのエントリ情報
struct MarkerEntry {
    let node: SKNode
    let name: String
    let tabNumber: Int?
    var direction: CallingDirection
}
