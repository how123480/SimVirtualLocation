// swift-tools-version:5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SimVirtualLocation",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        // Executable product for running the app
        .executable(
            name: "SimVirtualLocation",
            targets: ["SimVirtualLocation"]
        ),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // Add your dependencies here, for example:
        // .package(url: "https://github.com/example/package", from: "1.0.0"),
    ],
    targets: [
        // Main executable target (includes all source code)
        .executableTarget(
            name: "SimVirtualLocation",
            dependencies: [],
            path: "SimVirtualLocation",
            exclude: [
                "Assets.xcassets",
                "Info.plist",
                "SimVirtualLocation.entitlements",
                "helper-app.apk",
                ".venv"
            ],
            sources: [
                "Views",
                "Models",
                "Logic"
            ]
        ),
        .testTarget(
            name: "SimVirtualLocationTests",
            dependencies: ["SimVirtualLocation"]
        ),
    ]
)
