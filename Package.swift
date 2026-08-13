// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "wmp",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "WmpCore",
            resources: [.copy("Resources/th_words.txt"), .copy("Resources/en_words.txt")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "wmp",
            dependencies: ["WmpCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(name: "corpusgen", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
