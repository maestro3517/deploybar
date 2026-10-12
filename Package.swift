// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DeployBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeployBar",
            path: "Sources/DeployBar"
        )
    ]
)
