import Foundation

/// adjutant (`adj`) が残していく hub の記録1件。
///
/// `adj hub` は「このリポジトリの hub は自分だ」という印を1ファイル書いてから、
/// `exec` でエージェント本体に化ける。PID が引き継がれるので、記録の `pid` は
/// そのままエージェント本体の PID になり、台帳の `TaskRecord.pid` と突き合わせられる。
public struct AdjutantHub: Equatable {
    /// hub セッションを動かしているエージェント本体の PID
    public let pid: Int
    /// hub が座っている作業ディレクトリ (リポジトリの main checkout)
    public let cwd: String
    /// hub の宛名 ("adjutant-<owner>-<repo>-<16桁>")
    public let name: String

    public init(pid: Int, cwd: String, name: String) {
        self.pid = pid
        self.cwd = cwd
        self.name = name
    }
}

/// adjutant の記録置き場を読むだけの窓口。
///
/// adjutant が入っていない環境では置き場ごと存在しないので、常に空が返る。
/// 「入れている人にだけ hub 机が生える」という振る舞いを、判定ではなく不在で表す。
public enum AdjutantHubStore {
    /// 記録の置き場所。adjutant 側の `state_dir()` と同じ順序で決める。
    ///
    /// ここがずれると、動いている hub をいつまでも見つけられないまま
    /// 何のエラーも出ずに静かに空を返し続けることになる。優先順位まで揃える
    static func stateDirectory(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let dir = environment["ADJUTANT_STATE_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        }
        if let dir = environment["XDG_STATE_HOME"], !dir.isEmpty {
            return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
                .appendingPathComponent("adjutant")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/adjutant")
    }

    /// いま記録されている hub の一覧。
    ///
    /// 生死はここでは見ない。突き合わせる相手が台帳で、台帳は死んだセッションを
    /// すでに刈り取っているので、生きている台帳の行と一致した記録だけが残る。
    /// ここで `ps` を叩くと、机を描き直すたびにリポジトリの数だけプロセスを起こすことになる
    public static func hubs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [AdjutantHub] {
        let directory = stateDirectory(environment).appendingPathComponent("hubs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }

        return entries.filter { $0.pathExtension == "json" }.compactMap(hub(atPath:))
    }

    /// 記録1ファイルを読む。読めない・欠けているものは黙って捨てる。
    /// 書きかけのファイルを掴むことがあるので、壊れていることを異常として扱わない
    private static func hub(atPath url: URL) -> AdjutantHub? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = json["pid"] as? Int, pid > 0,
              let cwd = json["cwd"] as? String, !cwd.isEmpty,
              let name = json["hubName"] as? String, !name.isEmpty else { return nil }
        return AdjutantHub(pid: pid, cwd: cwd, name: name)
    }
}
