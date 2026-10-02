// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "OrbitCore", targets: ["OrbitCore"])],
    targets: [
        .target(name: "OrbitCore"),
        .testTarget(name: "OrbitCoreTests", dependencies: ["OrbitCore"])
    ]
)
