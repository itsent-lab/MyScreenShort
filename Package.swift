// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MyScreenShort",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MyScreenShort",
            targets: ["MyScreenShort"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MyScreenShort"
        )
    ],
    swiftLanguageVersions: [.v5]
)
