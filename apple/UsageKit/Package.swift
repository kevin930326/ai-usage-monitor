// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UsageKit",
    defaultLocalization: "zh-Hant",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "UsageKit", targets: ["UsageKit"]),
        .library(name: "UsageKitUI", targets: ["UsageKitUI"]),
    ],
    targets: [
        // 純邏輯：資料模型、解析、分級、中繼 API 用戶端
        .target(name: "UsageKit"),
        // 共用 SwiftUI 元件，iOS App、Live Activity、Mac App 共用
        .target(name: "UsageKitUI", dependencies: ["UsageKit"]),
        .testTarget(name: "UsageKitTests", dependencies: ["UsageKit"]),
    ]
)
