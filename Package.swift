// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Fluxio",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Fluxio",
            path: "Sources/Fluxio"
        )
    ]
)
