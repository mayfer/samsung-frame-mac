// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-detect-tv-ip",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "swift-detect-tv-ip",
            targets: ["swift-detect-tv-ip"]
        )
    ],
    targets: [
        .executableTarget(
            name: "swift-detect-tv-ip"
        )
    ]
)
