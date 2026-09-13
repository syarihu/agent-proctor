import CoreGraphics
import Foundation
import SpriteKit

/// ラベルを決まった幅に収めるための処理。
///
/// **文字数ではなく実寸で測る。** 日本語は英数字のほぼ倍幅なので、文字数で切ると
/// 日本語ならはみ出し、英数字なら枠の半分が余る。等幅フォントでも全角・半角の差は残るし、
/// 絵文字はさらに幅が違う。
enum LabelFitting {
    /// ラベルに文字を入れ、幅に収まらなければ末尾を削って「…」を付ける
    static func fit(_ label: SKLabelNode, text: String, maxWidth: CGFloat) {
        label.text = text
        guard !text.isEmpty, maxWidth > 0, label.frame.width > maxWidth else { return }

        var chars = Array(text)
        while chars.count > 1 {
            chars.removeLast()
            label.text = String(chars) + "…"
            if label.frame.width <= maxWidth { return }
        }
    }

    /// 幅に収まらないとき、末尾ではなく**先頭**を削って「…」を付ける。
    ///
    /// ブランチ名のように、末尾ほど区別が付くものに使う。
    /// `feature/` `fix/` のような接頭辞は複数の机で共通しがちで、そこを残しても見分けが付かない
    static func fitKeepingTail(_ label: SKLabelNode, text: String, maxWidth: CGFloat) {
        label.text = text
        guard !text.isEmpty, maxWidth > 0, label.frame.width > maxWidth else { return }

        var chars = Array(text)
        while chars.count > 1 {
            chars.removeFirst()
            label.text = "…" + String(chars)
            if label.frame.width <= maxWidth { return }
        }
    }

    /// 幅で折り返して複数行に分ける。
    ///
    /// 返るのは最大 `lineCount` 行。収まりきらないぶんは切り捨てるので、
    /// 呼ぶ側は各行を `fit` に通して末尾を省略させること。
    ///
    /// `probe` は幅を測るためだけに使う。表示中のラベルを渡してよい
    /// （このあと `fit` で本来の文字を入れ直すため）
    static func wrap(_ text: String, maxWidth: CGFloat,
                     lineCount: Int, probe: SKLabelNode) -> [String] {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !flat.isEmpty, maxWidth > 0, lineCount > 0 else { return [] }

        var lines: [String] = []
        var rest = flat

        for _ in 0..<lineCount {
            guard !rest.isEmpty else { break }
            probe.text = rest
            if probe.frame.width <= maxWidth {
                lines.append(rest)
                rest = ""
                break
            }

            // 収まる最長の前半を二分探索で探す
            let chars = Array(rest)
            var low = 1
            var high = chars.count
            var fitCount = 1
            while low <= high {
                let mid = (low + high) / 2
                probe.text = String(chars[0..<mid])
                if probe.frame.width <= maxWidth {
                    fitCount = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }

            // 単語や階層の途中で切らないよう、近くの区切りまで戻す
            var splitAt = fitCount
            let breaks: Set<Character> = [" ", "/", "-", "_", ":", "、", "。"]
            if let index = chars[0..<fitCount].lastIndex(where: { breaks.contains($0) }),
               index >= fitCount / 2 {
                // 区切り記号は行末に残す（空白だけは落とす）
                splitAt = chars[index] == " " ? index : index + 1
            }

            lines.append(String(chars[0..<splitAt]).trimmingCharacters(in: .whitespaces))
            rest = String(chars[splitAt...]).trimmingCharacters(in: .whitespaces)
        }

        return lines
    }
}
