import Foundation
import SwiftUI
import Model

/// 色は元の iTerm2 パネルの CSS から持ってきている。
/// ライト/ダークで変えるものだけ環境に追従させる
public enum Palette {
    public static let fg = Color.primary
    public static let dim = Color.secondary
    public static let hover = Color.gray.opacity(0.18)
    /// いま開いているタブの下地。帯 (spinner の色) と合わせて居場所を示す
    public static let current = Color.gray.opacity(0.13)
    public static let waiting = Color(red: 1.0, green: 0.655, blue: 0.149)     // #ffa726
    /// 終わったのにまだ見ていないもの。印 (✅) と揃えて緑にする
    public static let done = Color(red: 0.400, green: 0.733, blue: 0.416)      // #66bb6a
    public static let agents = Color(red: 0.671, green: 0.533, blue: 0.941)    // #ab88f0
    public static let added = Color(red: 0.298, green: 0.686, blue: 0.314)     // #4caf50
    public static let removed = Color(red: 0.937, green: 0.325, blue: 0.314)   // #ef5350
    public static let untracked = Color(red: 0.161, green: 0.714, blue: 0.965) // #29b6f6
    /// 行で数えられなかったファイル (バイナリ)。追加とも削除とも言えないので、
    /// 緑でも赤でもない色を当てる
    public static let binary = Color(red: 1.0, green: 0.655, blue: 0.149)      // #ffa726
    public static let spinner = Color(red: 0.310, green: 0.765, blue: 0.969)   // #4fc3f7
    /// いま触っているツールの行。主役はセッション名なので、
    /// 読めるが目を引かない程度に落とす
    public static let activity = Color.secondary.opacity(0.85)
    public static let claude = Color(red: 0.878, green: 0.478, blue: 0.345)       // #e07a58 (テラコッタ)
    public static let antigravity = Color(red: 0.353, green: 0.647, blue: 0.980)  // #5aa5fa (ブルー)
    public static let codex = Color(red: 0.063, green: 0.639, blue: 0.498)        // #10a37f (グリーン)

    /// PR の状態。同じ行に並ぶ diff バッジと同じ濃さで持つ。
    ///
    /// **タイトルの状態色 (`TaskRow.titleColor`) とは役目が違う。** あちらは
    /// 「まだ手を付けていないか」を示すもので、こちらは PR そのものの状態。
    /// 同じ行の diff が既に色を持っているので、ここに色を置いても浮かない
    public static let prOpen = Color(red: 0.298, green: 0.686, blue: 0.314)   // #4caf50
    public static let prMerged = Color(red: 0.671, green: 0.533, blue: 0.941) // #ab88f0
    public static let prClosed = Color(red: 0.937, green: 0.325, blue: 0.314) // #ef5350

    /// PR1件を何色で出すか。
    ///
    /// **下書きは状態より先に見る。** 開いてはいてもレビューには出ていないので、
    /// 開いている PR と同じ色で並べると、見てもらえる状態だと読み違える
    public static func pullRequest(_ ref: PullRequestRef) -> Color {
        if ref.isDraft { return dim }
        switch ref.state {
        case PullRequestState.open: return prOpen
        case PullRequestState.merged: return prMerged
        case PullRequestState.closed: return prClosed
        default: return dim
        }
    }

    /// 状態そのものを表す色。畳んだ見出しの内訳のように、
    /// 印と数だけで状態を見せる場所で使う。
    ///
    /// 行のタイトル (TaskRow.titleColor) とは別に持つ。あちらは読ませるのが仕事なので
    /// 実行中まで色を付けず、待たせているものだけを目立たせている
    public static func status(_ status: String) -> Color {
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
    public static func context(_ percent: Int) -> Color {
        if percent >= 80 { return removed }
        if percent >= 50 { return Color(red: 1.0, green: 0.718, blue: 0.302) } // #ffb74d
        return dim
    }
}
