import AppKit
import CryptoKit
import ImageIO

private enum PreviewCacheTier {
    case gridThumb
    case detailProxy

    var maxPixelSize: Int {
        switch self {
        case .gridThumb:
            return 1024
        case .detailProxy:
            return 2048
        }
    }

    var compressionFactor: CGFloat {
        switch self {
        case .gridThumb:
            return 0.78
        case .detailProxy:
            return 0.86
        }
    }
}

/// Asynchronous preview loader backed by ImageIO with:
/// - memory cache for grid thumbnails
/// - disk cache under PhotoSorter_Cache/GridThumb and DetailProxy
actor ThumbnailLoader {

    nonisolated static let shared = ThumbnailLoader()

    private static let detailProxySupportedExtensions: Set<String> = [
        "arw", "dng", "cr2", "cr3", "nef", "orf", "raf", "rw2",
    ]

    // MARK: - Configuration

    private static let maxGridMemoryCacheEntries: Int = 180

    // MARK: - Grid memory cache

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]
    private var insertionOrder: [String] = []

    // MARK: - Detail proxy generation

    private var detailInFlight: [String: Task<URL?, Never>] = [:]

    // MARK: - Public API

    /// Load a grid thumbnail for the image at `path`, using `GridThumb/` disk cache when `inputDir` is provided.
    func thumbnail(for path: String, inputDir: URL? = nil) async -> NSImage? {
        if let cached = cache[path] {
            if let inputDir, Self.cachedPreviewURLIfFresh(for: path, tier: .gridThumb, inputDir: inputDir) == nil {
                _ = Self.writePreviewFile(image: cached, to: Self.previewFileURL(for: path, tier: .gridThumb, inputDir: inputDir), compressionFactor: PreviewCacheTier.gridThumb.compressionFactor)
            }
            return cached
        }

        if Task.isCancelled {
            return nil
        }

        if let inputDir,
           let diskURL = Self.cachedPreviewURLIfFresh(for: path, tier: .gridThumb, inputDir: inputDir),
           let diskImage = NSImage(contentsOf: diskURL) {
            cacheGridImage(diskImage, for: path)
            return diskImage
        }

        if let task = inFlight[path] {
            let image = await task.value
            return Task.isCancelled ? nil : image
        }

        let task = Task.detached(priority: .userInitiated) {
            Self.loadThumbnail(at: path, maxPixelSize: PreviewCacheTier.gridThumb.maxPixelSize)
        }
        inFlight[path] = task

        let image = await task.value
        inFlight.removeValue(forKey: path)

        guard let image else {
            return nil
        }

        if let inputDir {
            _ = Self.writePreviewFile(
                image: image,
                to: Self.previewFileURL(for: path, tier: .gridThumb, inputDir: inputDir),
                compressionFactor: PreviewCacheTier.gridThumb.compressionFactor
            )
        }

        cacheGridImage(image, for: path)
        return Task.isCancelled ? nil : image
    }

    /// Ensure a disk-backed detail proxy exists and return its file URL.
    /// Returns `nil` if `inputDir` is unavailable or preview generation fails.
    func detailProxyURL(for path: String, inputDir: URL?) async -> URL? {
        guard let inputDir else { return nil }

        if let cachedURL = Self.cachedPreviewURLIfFresh(for: path, tier: .detailProxy, inputDir: inputDir) {
            return cachedURL
        }

        if Task.isCancelled {
            return nil
        }

        if let task = detailInFlight[path] {
            let url = await task.value
            return Task.isCancelled ? nil : url
        }

        let destinationURL = Self.previewFileURL(for: path, tier: .detailProxy, inputDir: inputDir)
        let task = Task.detached(priority: .utility) { () -> URL? in
            guard let image = Self.loadThumbnail(at: path, maxPixelSize: PreviewCacheTier.detailProxy.maxPixelSize) else {
                return nil
            }
            let ok = Self.writePreviewFile(
                image: image,
                to: destinationURL,
                compressionFactor: PreviewCacheTier.detailProxy.compressionFactor
            )
            return ok ? destinationURL : nil
        }
        detailInFlight[path] = task

        let url = await task.value
        detailInFlight.removeValue(forKey: path)
        return Task.isCancelled ? nil : url
    }

    func cachedGridThumbURLIfFresh(for path: String, inputDir: URL?) -> URL? {
        guard let inputDir else { return nil }
        return Self.cachedPreviewURLIfFresh(for: path, tier: .gridThumb, inputDir: inputDir)
    }

    func cachedDetailProxyURLIfFresh(for path: String, inputDir: URL?) -> URL? {
        guard let inputDir else { return nil }
        return Self.cachedPreviewURLIfFresh(for: path, tier: .detailProxy, inputDir: inputDir)
    }

    /// Invalidate the in-memory grid cache entry by path.
    func invalidate(path: String) {
        cache.removeValue(forKey: path)
        insertionOrder.removeAll { $0 == path }
        inFlight[path]?.cancel()
        inFlight.removeValue(forKey: path)
        detailInFlight[path]?.cancel()
        detailInFlight.removeValue(forKey: path)
    }

    /// Migrate cached previews when a photo is renamed.
    ///
    /// This preserves GridThumb/DetailProxy cache hits across CHECK renames so
    /// Quick Look does not need to re-decode RAW files for the same content.
    func migrateEntry(from oldPath: String, to newPath: String, inputDir: URL? = nil) {
        guard oldPath != newPath else { return }

        if let image = cache.removeValue(forKey: oldPath) {
            if let idx = insertionOrder.firstIndex(of: oldPath) {
                insertionOrder[idx] = newPath
            }
            cache[newPath] = image
        }

        if let task = inFlight.removeValue(forKey: oldPath) {
            task.cancel()
        }
        if let task = detailInFlight.removeValue(forKey: oldPath) {
            task.cancel()
        }

        guard let inputDir else { return }
        Self.migratePreviewFile(from: oldPath, to: newPath, tier: .gridThumb, inputDir: inputDir)
        Self.migratePreviewFile(from: oldPath, to: newPath, tier: .detailProxy, inputDir: inputDir)
    }

    // MARK: - Static helpers (cache path + freshness)

    nonisolated static func cachedGridThumbURLIfFresh(for path: String, inputDir: URL?) -> URL? {
        guard let inputDir else { return nil }
        return cachedPreviewURLIfFresh(for: path, tier: .gridThumb, inputDir: inputDir)
    }

    nonisolated static func supportsDetailProxy(for path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return detailProxySupportedExtensions.contains(ext)
    }

    nonisolated static func cachedDetailProxyURLIfFresh(for path: String, inputDir: URL?) -> URL? {
        guard let inputDir else { return nil }
        return cachedPreviewURLIfFresh(for: path, tier: .detailProxy, inputDir: inputDir)
    }

    // MARK: - Private helpers

    private func cacheGridImage(_ image: NSImage, for path: String) {
        if cache.count >= Self.maxGridMemoryCacheEntries, cache[path] == nil {
            evictOldest()
        }

        cache[path] = image
        insertionOrder.removeAll { $0 == path }
        insertionOrder.append(path)
    }

    /// Generate a proportional thumbnail using ImageIO and apply EXIF orientation.
    private static func loadThumbnail(at path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, sourceOptions as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            // Prefer embedded previews (especially valuable for RAW files).
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        )
    }

    private static func writePreviewFile(image: NSImage, to destinationURL: URL, compressionFactor: CGFloat) -> Bool {
        guard let data = jpegData(from: image, compressionFactor: compressionFactor) else {
            return false
        }

        do {
            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try data.write(to: destinationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func jpegData(from image: NSImage, compressionFactor: CGFloat) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .jpeg, properties: [
            .compressionFactor: compressionFactor,
        ])
    }

    private static func cachedPreviewURLIfFresh(for path: String, tier: PreviewCacheTier, inputDir: URL) -> URL? {
        let cacheURL = previewFileURL(for: path, tier: tier, inputDir: inputDir)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        let sourceURL = URL(fileURLWithPath: path)
        guard let sourceDate = modificationDate(for: sourceURL),
              let cacheDate = modificationDate(for: cacheURL) else {
            return nil
        }

        return cacheDate >= sourceDate ? cacheURL : nil
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func previewFileURL(for path: String, tier: PreviewCacheTier, inputDir: URL) -> URL {
        let directory: URL
        switch tier {
        case .gridThumb:
            directory = PhotoSorterCachePaths.gridThumbDirectory(for: inputDir)
        case .detailProxy:
            directory = PhotoSorterCachePaths.detailProxyDirectory(for: inputDir)
        }
        return directory.appendingPathComponent(pathHash(path)).appendingPathExtension("jpg")
    }

    private static func migratePreviewFile(from oldPath: String, to newPath: String, tier: PreviewCacheTier, inputDir: URL) {
        let fileManager = FileManager.default
        let oldURL = previewFileURL(for: oldPath, tier: tier, inputDir: inputDir)
        let newURL = previewFileURL(for: newPath, tier: tier, inputDir: inputDir)

        guard oldURL.path != newURL.path else { return }
        guard fileManager.fileExists(atPath: oldURL.path) else { return }

        do {
            try fileManager.createDirectory(
                at: newURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )

            if fileManager.fileExists(atPath: newURL.path) {
                return
            }

            try fileManager.copyItem(at: oldURL, to: newURL)
        } catch {
            // Best-effort cache migration; callers should continue without failing rename flow.
        }
    }

    private static func pathHash(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func evictOldest() {
        guard !insertionOrder.isEmpty else { return }
        let oldest = insertionOrder.removeFirst()
        cache.removeValue(forKey: oldest)
    }
}
