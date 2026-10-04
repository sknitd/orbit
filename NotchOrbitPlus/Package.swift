// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NotchCore", targets: ["NotchCore"])],
    targets: [
        .target(name: "NotchCore"),
        .testTarget(name: "NotchCoreTests", dependencies: ["NotchCore"])
    ]
)
