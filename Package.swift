// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeepSeekChat",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/MarkdownUI.git", from: "2.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/smittytone/HighlighterSwift.git", from: "3.1.0")
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekChat",
            dependencies: [
                .product(name: "MarkdownUI", package: "MarkdownUI"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Highlighter", package: "HighlighterSwift")
            ],
            path: "Sources/DeepSeekChat"
        ),
        .testTarget(
            name: "DeepSeekChatTests",
            dependencies: [
                "DeepSeekChat",
                .product(name: "MarkdownUI", package: "MarkdownUI"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Highlighter", package: "HighlighterSwift")
            ],
            path: "Tests/DeepSeekChatTests"
        )
    ]
)
