// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodeBubble",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CodeBubbleCore",
            path: "Sources/CodeBubbleCore"
        ),
        .executableTarget(
            name: "CodeBubble",
            dependencies: ["CodeBubbleCore"],
            path: "Sources/CodeBubble",
            resources: [
                .copy("Resources")
            ]
        ),
        .executableTarget(
            name: "codebubble-bridge",
            dependencies: ["CodeBubbleCore"],
            path: "Sources/CodeBubbleBridge"
        ),
        .testTarget(
            name: "CodeBubbleCoreTests",
            dependencies: ["CodeBubbleCore"],
            path: "Tests/CodeBubbleCoreTests"
        ),
        .testTarget(
            name: "CodeBubbleTests",
            dependencies: ["CodeBubble"],
            path: "Tests/CodeBubbleTests"
        ),
    ]
)
