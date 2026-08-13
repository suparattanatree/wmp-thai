// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "wmp",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(
            name: "WmpCore",
            resources: [.copy("Resources/curated_th.txt"), .copy("Resources/curated_en.txt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "wmp",
            dependencies: ["WmpCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "corpusgen", dependencies: ["WmpCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
