import Foundation

/// リポジトリ直下の .taskhub.json を読む。無ければ既定値を返す。
public enum ConfigStore {
    public static func load(repo: String) throws -> RepoConfig {
        var config = RepoConfig()
        let path = URL(fileURLWithPath: repo).appendingPathComponent(RepoConfig.fileName)

        if FileManager.default.fileExists(atPath: path.path) {
            let object: [String: Any]
            do {
                let data = try Data(contentsOf: path)
                guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { throw TaskhubError("中身がオブジェクトではありません") }
                object = parsed
            } catch {
                throw TaskhubError("\(RepoConfig.fileName) を読み込めません: \(error)")
            }

            if let value = object["baseBranch"] as? String { config.baseBranch = value }
            if let value = object["branchPrefix"] as? String { config.branchPrefix = value }
            if let value = object["worktreeDir"] as? String { config.worktreeDir = value }
            if let value = object["copyFiles"] as? [String] { config.copyFiles = value }
            if let value = object["copyGitExclude"] as? Bool { config.copyGitExclude = value }
            if let value = object["maxConcurrent"] as? Int { config.maxConcurrent = value }
            // agent だけは丸ごと差し替えず、指定されたキーだけ上書きする
            if let agent = object["agent"] as? [String: Any] {
                if let model = agent["model"] as? String { config.agent.model = model }
                if let mode = agent["permissionMode"] as? String {
                    config.agent.permissionMode = mode
                }
            }
        }

        if config.baseBranch?.isEmpty ?? true {
            config.baseBranch = GitClient.detectBaseBranch(repo)
        }
        return config
    }
}
