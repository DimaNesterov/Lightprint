// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LumenCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LumenCore", targets: ["LumenCore"]),
    ],
    targets: [
        .target(name: "LumenCore"),
        .testTarget(name: "LumenCoreTests", dependencies: ["LumenCore"]),
    ]
)
