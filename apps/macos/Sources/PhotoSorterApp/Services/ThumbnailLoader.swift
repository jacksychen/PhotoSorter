import AppKit
import ImageIO

/// An actor-based asynchronous thumbnail loader that uses native macOS
/// ImageIO for fast, EXIF-aware thumbnail generation with an in-memory cache.
actor ThumbnailLoader {

    // MARK: - Configuration

    /// Default thumbnail size in pixels (longest edge).
    private static let defaultSize: Int = 160

    /// Maximum number of cached thumbnails before eviction.
    private static let maxCacheEntries: Int = 500

    // MARK: - Cache

    /// Cached thumbnails keyed by file path.
    private var cache: [String: NSImage] = [:]

    /// Insertion-order tracking for simple LRU-like eviction.
    private var insertionOrder: [String] = []

    // MARK: - Public API

    /// Load a thumbnail for the image at `path`.
    ///
    /// Returns a cached `NSImage` if available, otherwise generates a
    /// thumbnail from disk using `CGImageSource` and caches it.
    ///
    /// - Parameters:
    ///   - path: Absolute file path to the source image.
    ///   - size: Maximum pixel dimension for the thumbnail (default 160).
    /// - Returns: An `NSImage` thumbnail, or `nil` if the image could not be read.
    func thumbnail(for path: String, size: Int = defaultSize) async -> NSImage? {
        // Check cache first.
        if let cached = cache[path] {
            return cached
        }

        // Generate thumbnail from disk.
        guard let image = loadThumbnail(at: path, maxPixelSize: size) else {
            return nil
        }

        // Evict oldest entry if the cache is full.
        if cache.count >= Self.maxCacheEntries {
            evictOldest()
        }

        cache[path] = image
        insertionOrder.append(path)

        return image
    }

    // MARK: - Private helpers

    /// Generate a thumbnail using `CGImageSource` from ImageIO.
    ///
    /// This is fast and automatically applies EXIF orientation via
    /// `kCGImageSourceCreateThumbnailWithTransform`.
    private func loadThumbnail(at path: String, maxPixelSize: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            options as CFDictionary
        ) else {
            return nil
        }

        let size = NSSize(
            width: CGFloat(cgImage.width),
            height: CGFloat(cgImage.height)
        )

        return NSImage(cgImage: cgImage, size: size)
    }

    /// Remove the oldest cache entry to stay within the size limit.
    private func evictOldest() {
        guard !insertionOrder.isEmpty else { return }
        let oldest = insertionOrder.removeFirst()
        cache.removeValue(forKey: oldest)
    }
}
