import ProctorKit

/// サブコマンドの引数。argparse の代わりに置いている小さな道具。
///
/// 外部依存を増やしてまで賄う規模ではないので手で持つ。
/// 今あるコマンドは値を取るオプションを持たないので、真偽値のフラグと
/// 位置引数だけを見る。
struct Args {
    private(set) var positional: [String] = []
    private var flags: Set<String> = []

    /// **`--` から先はフラグを探さない。** それより前は今までどおり、
    /// `-` で始まるものをフラグとして拾う。
    ///
    /// 置いたのは `title` のため。あれは人が書いた自由な文を受ける唯一のコマンドで、
    /// その文が `-` で始まると丸ごとフラグとして飲まれ、位置引数が空になる。
    /// 出るのは「名前を指定してください」——**渡しているのに、渡していないと言われる**。
    /// 逃げ道が無いと、その名前は付けられないままになる。
    ///
    /// `--` そのものは捨てる。区切りであって中身ではない。
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

    /// 値を持つオプションを取り出す (`--agent=codex`)。
    ///
    /// **値を次のトークンでは受けない。** `--agent codex` の形にすると、
    /// 値なのか位置引数なのかがここでは区別できず、`_touch running` の
    /// 状態そのものを取り違える。hooks の設定に書き写すものなので、
    /// 1つのトークンに収まっているほうが間違いも起きにくい
    func value(_ name: String) -> String? {
        let prefix = name + "="
        guard let hit = flags.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(hit.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    /// 位置引数を1つ取り出す。無ければ何が要るかを添えて止める。
    /// what は呼ぶ側が訳したもの (語順が言語で変わるので、文にするのはここ)
    ///
    /// **足りないうえにフラグを拾っているときだけ、`--` のことを言う。**
    /// `-` で始まる値はフラグとして飲まれるので、渡したのに「無い」と言われる。
    /// 逃げ道を知らないとそこで詰むが、`proctor attach` のように
    /// ID を忘れただけの場面で区切りの話をしても邪魔なだけなので、
    /// **何かをフラグとして拾っている**ときに限って添える
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
