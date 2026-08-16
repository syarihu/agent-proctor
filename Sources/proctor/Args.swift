import ProctorKit

/// サブコマンドの引数。argparse の代わりに置いている小さな道具。
///
/// 外部依存を増やしてまで賄う規模ではないので手で持つ。
/// 今あるコマンドは値を取るオプションを持たないので、真偽値のフラグと
/// 位置引数だけを見る。
struct Args {
    private(set) var positional: [String] = []
    private var flags: Set<String> = []

    init(_ argv: [String]) {
        for token in argv {
            if token.hasPrefix("-"), token != "-" {
                flags.insert(token)
            } else {
                positional.append(token)
            }
        }
    }

    func has(_ names: String...) -> Bool { names.contains { flags.contains($0) } }

    /// 位置引数を1つ取り出す。無ければ何が要るかを添えて止める
    func require(_ index: Int, _ what: String) throws -> String {
        guard index < positional.count else {
            throw ProctorError("\(what) を指定してください")
        }
        return positional[index]
    }
}
