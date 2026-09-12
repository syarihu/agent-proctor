import AppKit
import Foundation
import SpriteKit

// MARK: - 見取り図モデル

/// 机1つ。台帳の1セッションに対応する
struct DeskSeat: Equatable {
    /// `CollectedTask.id`。クリックで開く相手
    let id: String
    let name: String
    /// `CollectedTask.displayStatus`
    let status: String
    /// 人の手が要るか (`TaskStatus.needsPerson`)。カメラがここを最優先で映す
    let needsPerson: Bool
    let contextPercent: Int?
    /// 走っているサブエージェントの数。
    /// `agent_id` を送ってこないエージェントでは中身が空でも数だけ入る
    let subagents: Int
    /// 中身が分かるサブエージェント。分かるなら1体ずつ仕草を付けられる
    let helpers: [DeskHelper]
    /// いま触っているツール ("Edit: TaskStore.swift" など)。動いている間だけ入る。
    /// 何をしているかで仕草を変えるために使う
    let activity: String?
    /// 現在 iTerm2 で人間が見ているタブかどうか
    let isCurrent: Bool
    /// 対応するタブ番号（⌘1 など）
    let tabNumber: Int?
}

/// 机まわりの手伝い1人。台帳のサブエージェント1体に対応する
struct DeskHelper: Equatable {
    let id: String
    /// エージェント種別 ("Explore" など)
    let name: String
    /// いま触っているツール。親と同じ形式なので、同じ判定で仕草を決められる
    let activity: String?
}

/// 机の人の仕草。`activity` の頭 ("Edit: …" の Edit) から決める。
///
/// ツール名をそのまま出す代わりに、体の動きで言う。
/// 文字は小さくて読めないが、動きの違いは離れていても分かる
enum DeskGesture {
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
    static func from(activity: String?) -> DeskGesture {
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
struct DeskIsland: Equatable {
    let repo: String
    let seats: [DeskSeat]
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
