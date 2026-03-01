import Foundation

/// Custom resource bundle accessor that works correctly inside a macOS `.app` bundle.
///
/// SPM's auto-generated `Bundle.module` uses `Bundle.main.bundleURL` which resolves
/// to the `.app` root.  macOS code signing forbids placing files at that level, so
/// resource bundles are placed in `Contents/Resources/` (`Bundle.main.resourceURL`).
///
/// This accessor checks `resourceURL` first (packaged app), then falls back to
/// `bundleURL` (development / `swift run`).
private let _photoSorterAppBundle: Bundle = {
    let bundleName = "PhotoSorterApp_PhotoSorterApp"

    // Packaged macOS .app: Contents/Resources/<bundle>
    if let resourceURL = Bundle.main.resourceURL {
        let path = resourceURL.appendingPathComponent(bundleName + ".bundle").path
        if let bundle = Bundle(path: path) {
            return bundle
        }
    }

    // Development (swift run): same directory as the executable
    let devPath = Bundle.main.bundleURL.appendingPathComponent(bundleName + ".bundle").path
    if let bundle = Bundle(path: devPath) {
        return bundle
    }

    fatalError("could not load resource bundle: \(bundleName)")
}()

extension Foundation.Bundle {
    /// Resource bundle for the PhotoSorterApp (main) target, safe for `.app` bundles.
    static var appResources: Bundle { _photoSorterAppBundle }
}
