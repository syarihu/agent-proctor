import TaskhubKit

/// サブコマンドの引数。argparse の代わりに置いている小さな道具。
///
/// 外部依存を増やしてまで賄う規模ではないので手で持つ。
/// 値を取るオプションだけ先に教える形にして、`--base develop` と
/// `--json` を取り違えないようにする。
struct Args {
    private(set) var positional: [String] = []
    private var flags: Set<String> = []
    private var values: [String: String] = [:]

    /// - Parameters:
    ///   - valueOptions: 値を1つ取るオプション名 (`--` や `-` を含めた形)
    init(_ argv: [String], valueOptions: Set<String> = []) throws {
        var iterator = argv.makeIterator()
        while let token = iterator.next() {
            guard token.hasPrefix("-"), token != "-" else {
                positional.append(token)
                continue
            }
            // --name=value の形も受ける
            if let sep = token.firstIndex(of: "="), token.hasPrefix("--") {
                values[String(token[token.startIndex..<sep])] =
                    String(token[token.index(after: sep)...])
                continue
            }
            if valueOptions.contains(token) {
                guard let value = iterator.next() else {
                    throw TaskhubError("\(token) には値が必要です")
                }
                values[token] = value
            } else {
                flags.insert(token)
            }
        }
    }

    func has(_ names: String...) -> Bool { names.contains { flags.contains($0) } }

    func value(_ names: String...) -> String? {
        for name in names {
            if let found = values[name] { return found }
        }
        return nil
    }

    /// 位置引数を1つ取り出す。無ければ使い方を添えて止める
    func require(_ index: Int, _ what: String) throws -> String {
        guard index < positional.count else {
            throw TaskhubError("\(what) を指定してください")
        }
        return positional[index]
    }
}
