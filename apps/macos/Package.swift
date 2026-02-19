// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSorterApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PhotoSorterUI",
            path: "Sources/PhotoSorterApp"
        ),
        .executableTarget(
            name: "PhotoSorterApp",
            dependencies: ["PhotoSorterUI"],
            path: "Sources/PhotoSorterAppMain"
        ),
        .executableTarget(
            name: "PhotoSorterAppGUITests",
            dependencies: ["PhotoSorterUI"],
            path: "Sources/PhotoSorterAppGUITests"
        ),
    ]
)
