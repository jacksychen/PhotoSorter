// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSorterApp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "PhotoSorterApp",
            path: "Sources/PhotoSorterApp"
        ),
    ]
)
