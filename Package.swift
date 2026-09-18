// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FunkyShadow",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ShadowAPI", targets: ["ShadowAPI"]),
        .executable(name: "FunkyShadow", targets: ["FunkyShadow"]),
        .executable(name: "shadowctl", targets: ["shadowctl"]),
    ],
    targets: [
        .target(name: "ShadowAPI"),
        .target(
            name: "FunkyShadowUI",
            dependencies: ["ShadowAPI"],
            // .copy keeps the directory tree; .process would flatten it and break
            // spice-html5's relative ES-module imports.
            resources: [.copy("Resources/web")]
        ),
        .executableTarget(
            name: "FunkyShadow",
            dependencies: ["FunkyShadowUI"],
            // Embed Info.plist so `swift run` gets the same bundle id / ATS
            // settings as the assembled .app.
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ])
            ]
        ),
        .executableTarget(name: "shadowctl", dependencies: ["ShadowAPI"]),
        .testTarget(name: "ShadowAPITests", dependencies: ["ShadowAPI"]),
        .testTarget(name: "FunkyShadowUITests", dependencies: ["FunkyShadowUI"]),
    ]
)
