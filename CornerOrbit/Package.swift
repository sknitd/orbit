// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CornerOrbit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CornerCore", targets: ["CornerCore"])],
    targets: [
        .target(name: "CornerCore"),
        .testTarget(name: "CornerCoreTests", dependencies: ["CornerCore"])
    ],
    swiftLanguageModes: [.v6]
)
