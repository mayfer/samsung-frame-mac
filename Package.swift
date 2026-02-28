// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "samsung-frame-remote",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "SamsungFrameRemote", targets: ["SamsungFrameRemote"])
    ],
    targets: [
        .executableTarget(
            name: "SamsungFrameRemote",
            path: "SamsungFrameRemote/Sources",
            resources: [
                .copy("SamsungFrameRemote.sdef")
            ]
        )
    ]
)
