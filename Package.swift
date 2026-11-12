// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rais",
    defaultLocalization: "en",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "Rais", targets: ["Rais"]),
    ],
    targets: [
        .target(
            name: "Rais",
            path: "Sources/Rais",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "RaisTests",
            dependencies: ["Rais"],
            path: "Tests/RaisTests"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
