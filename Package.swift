// swift-tools-version: 6.0
import PackageDescription

// 外部依存は持たない。CLI は hooks から高い頻度で叩かれるので、
// 起動の速さと「取ってこなくてもビルドできる」ことを優先する。
let package = Package(
    name: "taskhub",
    platforms: [.macOS(.v13)],
    targets: [
        // 台帳・git・集計の実装。CLI とアプリの両方がここを通る。
        // 集計をここに閉じ込めることで、表示側にロジックが漏れるのを防ぐ
        .target(
            name: "TaskhubKit",
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "taskhub",
            dependencies: ["TaskhubKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // アプリ本体。scripts/install.sh がこれを Taskhub.app に組み立てる
        .executableTarget(
            name: "TaskhubApp",
            dependencies: ["TaskhubKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
