// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeepSeekChat",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DeepSeekChat",
            path: "Sources/DeepSeekChat"
        ),
        .testTarget(
            name: "DeepSeekChatTests",
            dependencies: ["DeepSeekChat"],
            path: "Tests/DeepSeekChatTests"
        )
    ]
)
