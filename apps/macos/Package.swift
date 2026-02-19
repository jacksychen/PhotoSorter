// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoSorterApp",
    platforms: [.macOS(.v26)],
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
    ],
    swiftLanguageModes: [.v5]
)
