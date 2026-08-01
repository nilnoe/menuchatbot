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
        .target(
            name: "CRustCore",
            path: "Sources/CRustCore",
            publicHeadersPath: "include",
            linkerSettings: [
                // 静态库由 scripts/build-rust-core.sh 统一产出（无 cargo 时为
                // 同 ABI stub 库，T2-1d）。相对路径统一从包根构建。
                .linkedLibrary("rustcore"),
                .unsafeFlags(["-L", "RustCore/dist"]),
            ]
        ),
        .target(
            name: "DeepSeekChatIndexing",
            dependencies: ["CRustCore"],
            path: "Sources/DeepSeekChatIndexing"
        ),
        .executableTarget(
            name: "DeepSeekChat",
            dependencies: [
                "DeepSeekChatIndexing",
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
                "DeepSeekChatIndexing",
                "CRustCore",
                .product(name: "MarkdownUI", package: "MarkdownUI"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Highlighter", package: "HighlighterSwift")
            ],
            path: "Tests/DeepSeekChatTests"
        )
    ]
)
