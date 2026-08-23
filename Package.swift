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
        // 台帳・git・集計の実装。CLI とアプリの両方がここを通る。
        // 集計をここに閉じ込めることで、表示側にロジックが漏れるのを防ぐ
        .target(
            name: "ProctorKit",
            // 表示する言葉は CLI とアプリで同じものを使うので、
            // 訳文も1か所 (Kit) に置いて両方から引く。
            // scripts/build-app.sh がここの .lproj を .app の中へ配る
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(
            name: "proctor",
            dependencies: ["ProctorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
        // アプリ本体。scripts/build-app.sh がこれを Agent Proctor.app に組み立てる
        .executableTarget(
            name: "ProctorApp",
            dependencies: ["ProctorKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
