// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Tilo",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(
            name: "CMpv",
            path: "Sources/CMpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"])]
        ),
        .target(
            name: "MpvBridge",
            dependencies: ["CMpv"],
            path: "Sources/MpvBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("CoreFoundation"),
                .linkedFramework("OpenGL"),
            ]
        ),
        .executableTarget(
            name: "Tilo",
            dependencies: ["CMpv", "MpvBridge"],
            path: "Sources/Tilo"
        ),
        .testTarget(name: "TiloTests", dependencies: ["Tilo"], path: "Tests/TiloTests")
    ]
)
