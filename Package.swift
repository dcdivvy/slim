// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SlimVideoPlayer",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "SlimVideoPlayer", targets: ["SlimVideoPlayer"])
    ],
    targets: [
        .executableTarget(
            name: "SlimVideoPlayer",
            path: "Sources/SlimVideoPlayer"
        )
    ]
)
