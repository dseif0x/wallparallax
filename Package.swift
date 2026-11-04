// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WallParallax",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WallParallax", path: "Sources/WallParallax")
    ]
)
