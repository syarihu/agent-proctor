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
        // レガシーブリッジ (移行期間中に順次切り出しを進める)
        // -------------------------------------------------------------
        .target(
            name: "ProctorKit",
            dependencies: [
                "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit", "RepositoryGitHub"
            ],
            path: "Sources/ProctorKit",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "proctor",
            dependencies: [
                "ProctorKit", "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit", "RepositoryGitHub"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // アプリ本体。scripts/build-app.sh がこれを Agent Proctor.app に組み立てる
        .executableTarget(
            name: "ProctorApp",
            dependencies: [
                "ProctorKit", "Model", "Utility", "Resources",
                "RepositoryLedger", "RepositoryGit", "RepositoryGitHub"
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
