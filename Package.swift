// swift-tools-version: 6.0
import PackageDescription

// 外部依存は持たない。CLI は hooks から高い頻度で叩かれるので、
// 起動の速さと「取ってこなくてもビルドできる」ことを優先する。
let package = Package(
    name: "proctor",
    // 訳が無い言語で立ち上げられたときはここに落ちる。文書と揃えて英語を正本にする
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    targets: [
        // -------------------------------------------------------------
        // 基盤層 (Core / Resources / Utility)
        // -------------------------------------------------------------
        .target(
            name: "Resources",
            path: "Sources/Resources",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "Model",
            dependencies: ["Resources"],
            path: "Sources/Model",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "Utility",
            path: "Sources/Utility",
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // -------------------------------------------------------------
        // リポジトリ層 (データソースごとに小分け)
        // -------------------------------------------------------------
        .target(
            name: "RepositoryLedger",
            dependencies: ["Model", "Utility", "Resources"],
            path: "Sources/Repository/Ledger",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "RepositoryGit",
            dependencies: ["Model", "Utility"],
            path: "Sources/Repository/Git",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "RepositoryGitHub",
            dependencies: ["Model", "Utility"],
            path: "Sources/Repository/GitHub",
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // -------------------------------------------------------------
        // ユースケース層 (ドメイン・機能ごとに小分け)
        // -------------------------------------------------------------
        .target(
            name: "UseCaseTask",
            dependencies: [
                "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit", "RepositoryGitHub"
            ],
            path: "Sources/UseCase/Task",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "UseCaseSession",
            dependencies: ["Model", "Utility", "Resources", "RepositoryLedger", "RepositoryGit"],
            path: "Sources/UseCase/Session",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "UseCaseWorktree",
            dependencies: ["Model", "Utility", "Resources", "RepositoryLedger", "RepositoryGit", "UseCaseTask"],
            path: "Sources/UseCase/Worktree",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "UseCaseNotice",
            dependencies: ["Model", "Utility", "Resources", "RepositoryLedger"],
            path: "Sources/UseCase/Notice",
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // -------------------------------------------------------------
        // デザインシステム & ブリッジ
        // -------------------------------------------------------------
        .target(
            name: "DesignSystem",
            dependencies: ["Model", "Utility", "Resources"],
            path: "Sources/DesignSystem",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "ItermBridge",
            dependencies: ["Model", "Utility", "Resources"],
            path: "Sources/Bridge/Iterm",
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // -------------------------------------------------------------
        // アプリケーション状態 (UI層で共有する状態管理)
        // -------------------------------------------------------------
        .target(
            name: "AppState",
            dependencies: [
                "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit",
                "UseCaseTask", "UseCaseSession", "UseCaseWorktree", "UseCaseNotice",
                "ItermBridge"
            ],
            path: "Sources/AppState",
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // -------------------------------------------------------------
        // フィーチャー層 (UIコンポーネント・画面)
        // -------------------------------------------------------------
        .target(
            name: "FeatureSettings",
            dependencies: [
                "Model", "Utility", "Resources", "DesignSystem", "ItermBridge",
                "UseCaseSession",
            ],
            path: "Sources/Feature/Settings",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "FeatureMenuBar",
            dependencies: ["Model", "Utility", "Resources", "DesignSystem", "AppState"],
            path: "Sources/Feature/MenuBar",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(
            name: "FeatureSidebar",
            dependencies: [
                "Model", "Utility", "Resources",
                "DesignSystem", "AppState",
                "UseCaseTask", "UseCaseWorktree", "UseCaseNotice",
                "ItermBridge"
            ],
            path: "Sources/Feature/Sidebar",
            swiftSettings: [.swiftLanguageMode(.v5)]),

        // -------------------------------------------------------------
        // エントリポイント (CLI & アプリ)
        // -------------------------------------------------------------
        .executableTarget(
            name: "proctor",
            dependencies: [
                "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit", "RepositoryGitHub",
                "UseCaseTask", "UseCaseSession", "UseCaseWorktree", "UseCaseNotice"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // アプリ本体。scripts/build-app.sh がこれを Agent Proctor.app に組み立てる
        .executableTarget(
            name: "ProctorApp",
            dependencies: [
                "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit", "RepositoryGitHub",
                "UseCaseTask", "UseCaseSession", "UseCaseWorktree", "UseCaseNotice",
                "DesignSystem", "ItermBridge", "AppState",
                "FeatureSettings", "FeatureMenuBar", "FeatureSidebar"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
