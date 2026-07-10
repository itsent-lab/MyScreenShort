// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MyScreenShortMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "MyScreenShortMac",
            targets: ["MyScreenShortMac"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MyScreenShortMac"
        )
    ],
    swiftLanguageVersions: [.v5]
)
