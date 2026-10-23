// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "pump",
    targets: [
        .executableTarget(
            name: "pump",
            path: "Sources/pump"
        )
    ]
)
