// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PhotoSorterApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "PhotoSorterUI",
            path: "Sources/PhotoSorterApp",
            sources: [
                "ContentView.swift",
                "Models/AppState.swift",
                "Models/ManifestResult.swift",
                "Models/PipelineMessage.swift",
                "Models/PipelineParameters.swift",
                "Services/PipelineRunner.swift",
                "Services/ThumbnailLoader.swift",
                "Views/ClusterSidebar.swift",
                "Views/FolderSelectView.swift",
                "Views/ParameterView.swift",
                "Views/PathControlView.swift",
                "Views/PhotoDetailView.swift",
                "Views/PhotoDetailWindowController.swift",
                "Views/PhotoGridView.swift",
                "Views/PipelineProgressView.swift",
                "Views/ResultView.swift",
            ]
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
