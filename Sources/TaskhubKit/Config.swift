import Foundation

public struct AgentConfig: Equatable {
    public var model: String?
    public var permissionMode: String = "acceptEdits"
}

/// リポジトリ直下の .taskhub.json で `new` の挙動を変えられる。無くても動く。
public struct RepoConfig: Equatable {
    /// nil なら origin/HEAD から推定する
    public var baseBranch: String?
    public var branchPrefix: String = ""
    public var worktreeDir: String = ".claude/worktrees"
    /// gitignore されていて worktree に引き継がれないファイルを持ち込む
    public var copyFiles: [String] = []
    public var copyGitExclude: Bool = true
    public var maxConcurrent: Int = 3
    public var agent = AgentConfig()

    public static let fileName = ".taskhub.json"
}

public enum Config {
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

        if config.baseBranch == nil || config.baseBranch?.isEmpty == true {
            config.baseBranch = try detectBaseBranch(repo: repo)
        }
        return config
    }

    /// origin/HEAD → develop/main/master の順にベースブランチを推定する。
    public static func detectBaseBranch(repo: String) throws -> String {
        let head = try git(repo, "symbolic-ref", "--quiet", "--short",
                           "refs/remotes/origin/HEAD", check: false, quiet: true)
        if head.contains("/") {
            return String(head.split(separator: "/", maxSplits: 1)[1])
        }
        for candidate in ["develop", "main", "master"] {
            if gitOK(repo, "rev-parse", "--verify", "refs/remotes/origin/\(candidate)") {
                return candidate
            }
        }
        return try git(repo, "rev-parse", "--abbrev-ref", "HEAD", check: false, quiet: true)
    }

    /// メイン worktree のパスを返す。worktree の中から呼ばれても本体を指す。
    ///
    /// --git-common-dir はどの worktree から見ても共通の .git を指すので、
    /// その親がメインリポジトリになる。
    public static func repoRoot(start: String? = nil, strict: Bool = true) throws -> String? {
        let from = start ?? FileManager.default.currentDirectoryPath
        let (ok, output) = gitTry(from, "rev-parse", "--git-common-dir")
        guard ok, !output.isEmpty else {
            if strict { throw TaskhubError("git リポジトリの中で実行してください") }
            return nil
        }
        var common = URL(fileURLWithPath: output)
        if !output.hasPrefix("/") {
            common = URL(fileURLWithPath: from).appendingPathComponent(output)
        }
        return common.resolvingSymlinksInPath()
            .deletingLastPathComponent().path
    }
}
