import Foundation

public struct AgentConfig: Equatable {
    public var model: String?
    public var permissionMode: String = "acceptEdits"

    public init(model: String? = nil, permissionMode: String = "acceptEdits") {
        self.model = model
        self.permissionMode = permissionMode
    }
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

    public init() {}
}
