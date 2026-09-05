import Model
import Resources

/// CLI 引数のパース構造体。外部依存を避けるため最小限の実装（フラグ・オプション・位置引数）を提供する。
struct Args {
    private(set) var positional: [String] = []
    private var flags: Set<String> = []

    /// '--' 以降のトークンはハイフンで始まっていてもフラグとみなさず位置引数として扱う。
    /// タイトル文字列などが '-' で始まる場合に誤ってフラグ判定されるのを防ぐ。
    init(_ argv: [String]) {
        var sawSeparator = false
        for token in argv {
            if !sawSeparator, token == "--" {
                sawSeparator = true
                continue
            }
            if !sawSeparator, token.hasPrefix("-"), token != "-" {
                flags.insert(token)
            } else {
                positional.append(token)
            }
        }
    }

    func has(_ names: String...) -> Bool { names.contains { flags.contains($0) } }

    /// 値を持つオプションを取り出す（--key=value 形式）。
    /// 次のトークンを値として扱う形式（--key value）は位置引数との曖昧さを生むため、同一トークン内の '=' 区切りのみ受け付ける。
    func value(_ name: String) -> String? {
        let prefix = name + "="
        guard let hit = flags.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(hit.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// 指定インデックスの位置引数を取得する。不足時はエラーを送出する。
    /// フラグとして誤認識されている可能性を考慮し、flags が空でない場合は '--' の使用を促すメッセージに切り替える。
    func require(_ index: Int, _ what: String) throws -> String {
        guard index < positional.count else {
            let key = flags.isEmpty
                ? "cli.error.missing_argument"
                : "cli.error.missing_argument_after_flags"
            throw ProctorError(Localized.text(key, what))
        }
        return positional[index]
    }
}
