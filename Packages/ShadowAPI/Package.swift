// swift-tools-version:5.9
import PackageDescription

// The Shadow API wrapper and its headless CLI. The app itself is built by the
// Xcode project (see ../../project.yml), which depends on this package.
let package = Package(
    name: "ShadowAPI",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ShadowAPI", targets: ["ShadowAPI"]),
        .executable(name: "shadowctl", targets: ["shadowctl"]),
    ],
    targets: [
        .target(name: "ShadowAPI"),
        .executableTarget(name: "shadowctl", dependencies: ["ShadowAPI"]),
        .testTarget(name: "ShadowAPITests", dependencies: ["ShadowAPI"]),
    ]
)
