// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "McGrammar",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "McGrammar",
            path: "Sources/McGrammar"
        )
    ]
)
