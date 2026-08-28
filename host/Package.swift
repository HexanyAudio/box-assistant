// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BoxRevealHost",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BoxRevealHost",
            path: "Sources/BoxRevealHost"
        )
    ]
)
