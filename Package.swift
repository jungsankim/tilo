// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tilo",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Tilo", path: "Sources/Tilo")
    ]
)
