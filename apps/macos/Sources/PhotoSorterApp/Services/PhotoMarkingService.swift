import Foundation

public enum PhotoMarkingError: LocalizedError {
    case missingInputDirectory
    case invalidSelection
    case filenameConflict(String)
    case renameFailed(String)
    case manifestWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingInputDirectory:
            return String(localized: "No input directory selected.", bundle: .appResources)
        case .invalidSelection:
            return String(localized: "Invalid photo selection.", bundle: .appResources)
        case .filenameConflict(let name):
            return String(
                format: String(localized: "Target filename already exists: %@", bundle: .appResources),
                locale: .current,
                name
            )
        case .renameFailed(let reason):
            return String(
                format: String(localized: "Failed to rename photo: %@", bundle: .appResources),
                locale: .current,
                reason
            )
        case .manifestWriteFailed(let reason):
            return String(
                format: String(localized: "Failed to persist manifest.json: %@", bundle: .appResources),
                locale: .current,
                reason
            )
        }
    }
}

public struct PhotoMarkingService {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func toggleMark(
        manifest: ManifestResult,
        inputDir: URL,
        clusterIndex: Int,
        photoIndex: Int
    ) throws -> ManifestResult {
        guard clusterIndex >= 0, clusterIndex < manifest.clusters.count else {
            throw PhotoMarkingError.invalidSelection
        }
        guard photoIndex >= 0, photoIndex < manifest.clusters[clusterIndex].photos.count else {
            throw PhotoMarkingError.invalidSelection
        }

        let sourcePhoto = manifest.clusters[clusterIndex].photos[photoIndex]
        let sourceURL = URL(fileURLWithPath: sourcePhoto.originalPath)
        let targetFilename = sourcePhoto.toggledFilename()
        let targetURL = sourceURL.deletingLastPathComponent().appendingPathComponent(targetFilename)

        if fileManager.fileExists(atPath: targetURL.path) {
            throw PhotoMarkingError.filenameConflict(targetFilename)
        }

        do {
            try fileManager.moveItem(at: sourceURL, to: targetURL)
        } catch {
            throw PhotoMarkingError.renameFailed(error.localizedDescription)
        }

        var updatedManifest = manifest
        updatedManifest.clusters[clusterIndex].photos[photoIndex].filename = targetFilename
        updatedManifest.clusters[clusterIndex].photos[photoIndex].originalPath = targetURL.path

        let manifestURL = PhotoSorterCachePaths.manifestURL(for: inputDir)
        do {
            try writeManifest(updatedManifest, to: manifestURL)
        } catch {
            let rollbackError = rollbackRename(from: targetURL, to: sourceURL)
            let rollbackSuffix = rollbackError.map {
                String(
                    format: String(localized: " Rollback failed: %@", bundle: .appResources),
                    locale: .current,
                    $0.localizedDescription
                )
            } ?? ""
            throw PhotoMarkingError.manifestWriteFailed(error.localizedDescription + rollbackSuffix)
        }

        return updatedManifest
    }

    private func writeManifest(_ manifest: ManifestResult, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(manifest)
        if data.last != 0x0A {
            data.append(0x0A)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: url, options: .atomic)
    }

    private func rollbackRename(from sourceURL: URL, to destinationURL: URL) -> Error? {
        do {
            guard fileManager.fileExists(atPath: sourceURL.path) else { return nil }
            if fileManager.fileExists(atPath: destinationURL.path) {
                return PhotoMarkingError.filenameConflict(destinationURL.lastPathComponent)
            }
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            return nil
        } catch {
            return error
        }
    }
}
