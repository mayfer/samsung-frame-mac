// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "frame-mac-app",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "FrameMacApp", targets: ["FrameMacApp"])
    ],
    targets: [
        .executableTarget(
            name: "FrameMacApp",
            path: "FrameMacApp/Sources"
        )
    ]
)
