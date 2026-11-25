// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Eave",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Eave",
            path: "Sources/Eave"
        )
    ]
)
