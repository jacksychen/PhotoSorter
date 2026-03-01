// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoSorterApp",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "PhotoSorterUI",
            path: "Sources/PhotoSorterApp",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "PhotoSorterApp",
            dependencies: ["PhotoSorterUI"],
            path: "Sources/PhotoSorterAppMain",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "PhotoSorterAppGUITests",
            dependencies: ["PhotoSorterUI"],
            path: "Sources/PhotoSorterAppGUITests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
