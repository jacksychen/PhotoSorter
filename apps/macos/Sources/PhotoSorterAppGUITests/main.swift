import AppKit
import Foundation
import PhotoSorterUI
import QuickLookUI

private struct TestFailure: Error {
    let message: String
}

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(message: message)
    }
}

@MainActor
private func makePhotos(prefix: String = "IMG") -> [ManifestResult.Photo] {
    [
        ManifestResult.Photo(position: 0, originalIndex: 0, filename: "\(prefix)_1.jpg", originalPath: "/tmp/\(prefix)_1.jpg"),
        ManifestResult.Photo(position: 1, originalIndex: 1, filename: "\(prefix)_2.jpg", originalPath: "/tmp/\(prefix)_2.jpg"),
        ManifestResult.Photo(position: 2, originalIndex: 2, filename: "\(prefix)_3.jpg", originalPath: "/tmp/\(prefix)_3.jpg"),
    ]
}

@MainActor
private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
    let fileManager = FileManager.default
    let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let directory = base.appendingPathComponent("photosorter-ui-tests-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: directory) }
    try body(directory)
}

@MainActor
private func makeSinglePhotoManifest(in directory: URL, filename: String = "IMG_1.jpg") -> ManifestResult {
    let photo = ManifestResult.Photo(
        position: 0,
        originalIndex: 0,
        filename: filename,
        originalPath: directory.appendingPathComponent(filename).path
    )
    let cluster = ManifestResult.Cluster(clusterId: 0, count: 1, photos: [photo])
    return ManifestResult(
        version: 1,
        inputDir: directory.path,
        total: 1,
        parameters: nil,
        clusters: [cluster]
    )
}

@MainActor
private func testKeyActionMapping() throws {
    try expect(PhotoDetailKeyAction.from(keyCode: 123) == .previous, "Left key should map to previous")
    try expect(PhotoDetailKeyAction.from(keyCode: 124) == .next, "Right key should map to next")
    try expect(PhotoDetailKeyAction.from(keyCode: 126) == .previous, "Up key should map to previous")
    try expect(PhotoDetailKeyAction.from(keyCode: 125) == .next, "Down key should map to next")
    try expect(PhotoDetailKeyAction.from(keyCode: 53) == .close, "Escape key should map to close")
    try expect(PhotoDetailKeyAction.from(keyCode: 49) == .close, "Space key should map to close for Quick Look toggle")
    try expect(PhotoDetailKeyAction.from(keyCode: 36) == .toggleMark, "Return key should map to toggle mark")
    try expect(PhotoDetailKeyAction.from(keyCode: 76) == .toggleMark, "Keypad Enter should map to toggle mark")
    try expect(PhotoDetailKeyAction.from(keyCode: 48) == nil, "Unmapped key should return nil")
}

@MainActor
private func testWindowNativeStyleAndControllerNavigation() throws {
    let photos = makePhotos(prefix: "NAV")
    var observedIndices: [Int] = []
    var observedToggleRequests: [Int] = []
    let controller = PhotoDetailWindowController(photos: photos, currentIndex: 1)
    let callbackController = PhotoDetailWindowController(
        photos: photos,
        currentIndex: 1,
        onCurrentIndexChanged: { observedIndices.append($0) },
        onToggleMarkRequested: { observedToggleRequests.append($0) }
    )

    controller.show()
    guard let window = controller.window else {
        throw TestFailure(message: "PhotoDetailWindowController should create Quick Look panel after show")
    }

    try expect(window is QLPreviewPanel, "Controller should reuse native QLPreviewPanel")
    try expect(window.isVisible, "Quick Look panel should be visible after show")
    try expect(controller.currentIndex == 1, "Initial current index should match selected photo")

    controller.handle(.previous)
    try expect(controller.currentIndex == 0, "Previous action should move current index")

    controller.handle(.next)
    try expect(controller.currentIndex == 1, "Next action should move current index")

    callbackController.handle(.next)
    callbackController.handle(.previous)
    try expect(observedIndices == [2, 1], "Controller should report index changes while navigating photos")

    callbackController.handle(.toggleMark)
    try expect(observedToggleRequests == [1], "Controller should report mark toggle on currently selected photo index")

    controller.update(photos: photos, currentIndex: 2)
    try expect(controller.currentIndex == 2, "Update should refresh selected index")

    controller.handle(.close)
    try expect(controller.currentIndex == 2, "Close action should not mutate current index")
}

@MainActor
private func testControllerNavigationStaysWithinCluster() throws {
    let clusterPhotos = makePhotos(prefix: "A")

    let controller = PhotoDetailWindowController(
        photos: clusterPhotos,
        currentIndex: 1
    )

    controller.show()
    guard let window = controller.window else {
        throw TestFailure(message: "PhotoDetailWindowController should create panel for cluster navigation test")
    }

    try expect(window is QLPreviewPanel, "In-cluster navigation should run on QLPreviewPanel")
    try expect(controller.currentIndex == 1, "Initial index should point to cluster index 1")

    controller.handle(.next)
    try expect(controller.currentIndex == 2, "Within-cluster next should advance photo index")

    controller.handle(.next)
    try expect(controller.currentIndex == 2, "At upper bound, next should keep current-cluster selection")

    controller.handle(.previous)
    try expect(controller.currentIndex == 1, "Within-cluster previous should move index backward")

    controller.handle(.previous)
    controller.handle(.previous)
    try expect(controller.currentIndex == 0, "Within-cluster previous should clamp to first photo")

    controller.handle(.previous)
    try expect(controller.currentIndex == 0, "At lower bound, previous should keep first photo selected")
    controller.handle(.close)
}

@MainActor
private func testControllerCloseResetsPanelReferenceAndKeepsSelection() throws {
    let clusterPhotos = makePhotos(prefix: "CA")
    var observedIndices: [Int] = []

    let controller = PhotoDetailWindowController(
        photos: clusterPhotos,
        currentIndex: 1,
        onCurrentIndexChanged: { observedIndices.append($0) }
    )

    controller.show()
    try expect(controller.window != nil, "Controller should expose panel window after show")

    controller.handle(.next)
    controller.handle(.next)
    controller.handle(.next)
    try expect(controller.currentIndex == 2, "Photo index should clamp at current cluster upper bound before close")

    observedIndices.removeAll()
    controller.handle(.close)

    let closeDeadline = Date().addingTimeInterval(1.0)
    while controller.window != nil && Date() < closeDeadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    try expect(observedIndices.isEmpty, "Close should not emit synthetic index-change callbacks")
    try expect(controller.window == nil, "Controller should clear panel reference after close")
    try expect(controller.currentIndex == 2, "Close should keep the selected in-cluster index")

    controller.show()
    try expect(controller.window != nil, "Controller should reopen panel after close")
    try expect(controller.currentIndex == 2, "Reopen should keep selected index for current cluster")
    controller.handle(.close)
}

@MainActor
private func testPhotoMarkingServiceToggleAndManifestPersistence() throws {
    try withTemporaryDirectory { directory in
        let fileManager = FileManager.default
        let originalURL = directory.appendingPathComponent("IMG_1.jpg")
        try Data([0x01, 0x02]).write(to: originalURL)

        let service = PhotoMarkingService()
        let manifest = makeSinglePhotoManifest(in: directory)
        let marked = try service.toggleMark(manifest: manifest, inputDir: directory, clusterIndex: 0, photoIndex: 0)

        let checkedURL = directory.appendingPathComponent("CHECK_IMG_1.jpg")
        try expect(marked.clusters[0].photos[0].filename == "CHECK_IMG_1.jpg", "Marking should prefix filename with CHECK_")
        try expect(fileManager.fileExists(atPath: checkedURL.path), "Marking should rename file on disk")

        let persistedData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let persisted = try JSONDecoder().decode(ManifestResult.self, from: persistedData)
        try expect(persisted.clusters[0].photos[0].filename == "CHECK_IMG_1.jpg", "Marking should write updated filename to manifest.json")
        try expect(persisted.clusters[0].photos[0].isChecked, "Persisted filename prefix should drive checked state")

        let unmarked = try service.toggleMark(manifest: marked, inputDir: directory, clusterIndex: 0, photoIndex: 0)
        try expect(unmarked.clusters[0].photos[0].filename == "IMG_1.jpg", "Unmarking should remove CHECK_ prefix")
        try expect(fileManager.fileExists(atPath: originalURL.path), "Unmarking should restore original filename on disk")
    }
}

@MainActor
private func testPhotoMarkingServiceConflictDoesNotRename() throws {
    try withTemporaryDirectory { directory in
        let fileManager = FileManager.default
        let sourceURL = directory.appendingPathComponent("IMG_1.jpg")
        let conflictURL = directory.appendingPathComponent("CHECK_IMG_1.jpg")
        try Data([0x01]).write(to: sourceURL)
        try Data([0x02]).write(to: conflictURL)

        let service = PhotoMarkingService()
        let manifest = makeSinglePhotoManifest(in: directory)

        do {
            _ = try service.toggleMark(manifest: manifest, inputDir: directory, clusterIndex: 0, photoIndex: 0)
            throw TestFailure(message: "Expected filename conflict error")
        } catch let error as PhotoMarkingError {
            guard case .filenameConflict = error else {
                throw TestFailure(message: "Expected filenameConflict, got \(error.localizedDescription)")
            }
        }

        try expect(fileManager.fileExists(atPath: sourceURL.path), "Conflict should not rename original file")
        try expect(fileManager.fileExists(atPath: conflictURL.path), "Conflict should keep existing target file untouched")
    }
}

@MainActor
private func testPhotoMarkingServiceRenameFailure() throws {
    try withTemporaryDirectory { directory in
        let missingPath = directory.appendingPathComponent("missing.jpg").path
        let missingPhoto = ManifestResult.Photo(
            position: 0,
            originalIndex: 0,
            filename: "missing.jpg",
            originalPath: missingPath
        )
        let manifest = ManifestResult(
            version: 1,
            inputDir: directory.path,
            total: 1,
            parameters: nil,
            clusters: [ManifestResult.Cluster(clusterId: 0, count: 1, photos: [missingPhoto])]
        )

        do {
            _ = try PhotoMarkingService().toggleMark(
                manifest: manifest,
                inputDir: directory,
                clusterIndex: 0,
                photoIndex: 0
            )
            throw TestFailure(message: "Expected rename failure for missing source file")
        } catch let error as PhotoMarkingError {
            guard case .renameFailed = error else {
                throw TestFailure(message: "Expected renameFailed, got \(error.localizedDescription)")
            }
        }
    }
}

@main
struct PhotoSorterAppGUITests {
    private static let allTests: [(String, @MainActor () throws -> Void)] = [
        ("Photo detail key mapping", testKeyActionMapping),
        ("Photo detail native window + navigation", testWindowNativeStyleAndControllerNavigation),
        ("Photo detail in-cluster navigation", testControllerNavigationStaysWithinCluster),
        ("Photo detail close cleanup + selection", testControllerCloseResetsPanelReferenceAndKeepsSelection),
        ("Photo marking persists rename + manifest", testPhotoMarkingServiceToggleAndManifestPersistence),
        ("Photo marking conflict guard", testPhotoMarkingServiceConflictDoesNotRename),
        ("Photo marking rename failure", testPhotoMarkingServiceRenameFailure),
    ]

    @MainActor
    private static func runTests(caseName: String?) -> Int32 {
        let testsToRun: [(String, @MainActor () throws -> Void)]
        if let caseName {
            guard let selected = allTests.first(where: { $0.0 == caseName }) else {
                print("FAIL: Unknown GUI test case '\(caseName)'")
                print("Available cases:")
                allTests.forEach { print("- \($0.0)") }
                return EXIT_FAILURE
            }
            testsToRun = [selected]
        } else {
            testsToRun = allTests
        }

        var failures: [String] = []

        for (name, test) in testsToRun {
            do {
                try test()
                print("PASS: \(name)")
            } catch let failure as TestFailure {
                failures.append("FAIL: \(name) -> \(failure.message)")
            } catch {
                failures.append("FAIL: \(name) -> \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            print("All GUI tests passed (\(testsToRun.count)/\(testsToRun.count)).")
            return EXIT_SUCCESS
        }

        failures.forEach { print($0) }
        print("GUI tests failed (\(failures.count)/\(testsToRun.count)).")
        return EXIT_FAILURE
    }

    private static func parseCaseName() -> String? {
        let args = CommandLine.arguments
        guard let caseFlagIndex = args.firstIndex(of: "--case") else { return nil }
        let nameIndex = args.index(after: caseFlagIndex)
        guard nameIndex < args.endIndex else { return nil }
        return args[nameIndex]
    }

    @MainActor
    static func main() {
        let exitCode = runTests(caseName: parseCaseName())
        exit(exitCode)
    }
}
