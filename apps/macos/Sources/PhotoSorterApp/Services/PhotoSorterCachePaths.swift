import Foundation

enum PhotoSorterCachePaths {
    static let cacheDirectoryName = "PhotoSorter_Cache"
    static let gridThumbDirectoryName = "GridThumb"
    static let detailProxyDirectoryName = "DetailProxy"
    static let manifestFilename = "manifest.json"

    static func cacheDirectory(for inputDir: URL) -> URL {
        inputDir.appendingPathComponent(cacheDirectoryName, isDirectory: true)
    }

    static func manifestURL(for inputDir: URL) -> URL {
        cacheDirectory(for: inputDir).appendingPathComponent(manifestFilename)
    }

    static func gridThumbDirectory(for inputDir: URL) -> URL {
        cacheDirectory(for: inputDir).appendingPathComponent(gridThumbDirectoryName, isDirectory: true)
    }

    static func detailProxyDirectory(for inputDir: URL) -> URL {
        cacheDirectory(for: inputDir).appendingPathComponent(detailProxyDirectoryName, isDirectory: true)
    }
}
