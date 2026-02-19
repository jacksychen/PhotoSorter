import AppKit
import Foundation
import PhotoSorterUI

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
private func testStateClamp() throws {
    let photos = makePhotos()
    let low = PhotoDetailState(photos: photos, currentIndex: -2)
    let high = PhotoDetailState(photos: photos, currentIndex: 99)

    try expect(low.currentIndex == 0, "PhotoDetailState should clamp low index to 0")
    try expect(high.currentIndex == photos.count - 1, "PhotoDetailState should clamp high index to last item")
}

@MainActor
private func testStateNavigationBounds() throws {
    let photos = makePhotos()
    let state = PhotoDetailState(photos: photos, currentIndex: 1)

    state.navigatePrevious()
    try expect(state.currentIndex == 0, "navigatePrevious should move index from 1 to 0")

    state.navigatePrevious()
    try expect(state.currentIndex == 0, "navigatePrevious should stay at lower bound")

    state.navigateNext()
    state.navigateNext()
    try expect(state.currentIndex == 2, "navigateNext should reach upper bound")

    state.navigateNext()
    try expect(state.currentIndex == 2, "navigateNext should stay at upper bound")
}

@MainActor
private func testKeyActionMapping() throws {
    try expect(PhotoDetailKeyAction.from(keyCode: 123) == .previous, "Left key should map to previous")
    try expect(PhotoDetailKeyAction.from(keyCode: 124) == .next, "Right key should map to next")
    try expect(PhotoDetailKeyAction.from(keyCode: 53) == .close, "Escape key should map to close")
    try expect(PhotoDetailKeyAction.from(keyCode: 36) == nil, "Unmapped key should return nil")
}

@MainActor
private func testWindowNativeStyleAndControllerNavigation() throws {
    let photos = makePhotos(prefix: "NAV")
    let controller = PhotoDetailWindowController(photos: photos, currentIndex: 1)

    guard let window = controller.window else {
        throw TestFailure(message: "PhotoDetailWindowController should create a window")
    }

    try expect(window.styleMask.contains(.titled), "Window should be titled")
    try expect(window.styleMask.contains(.closable), "Window should be closable")
    try expect(window.styleMask.contains(.miniaturizable), "Window should be miniaturizable")
    try expect(window.styleMask.contains(.resizable), "Window should be resizable")
    try expect(window.title == "NAV_2.jpg", "Initial title should match current photo")

    controller.handle(.previous)
    try expect(window.title == "NAV_1.jpg", "Previous action should update title")

    controller.handle(.next)
    try expect(window.title == "NAV_2.jpg", "Next action should update title")

    controller.update(photos: photos, currentIndex: 2)
    try expect(window.title == "NAV_3.jpg", "Update should refresh title to selected photo")

    window.makeKeyAndOrderFront(nil)
    try expect(window.isVisible, "Window should become visible when ordered front")

    controller.handle(.close)
    try expect(!window.isVisible, "Close action should close the detail window")
}

@main
struct PhotoSorterAppGUITests {
    private static let allTests: [(String, @MainActor () throws -> Void)] = [
        ("PhotoDetailState clamps index", testStateClamp),
        ("PhotoDetailState navigation bounds", testStateNavigationBounds),
        ("Photo detail key mapping", testKeyActionMapping),
        ("Photo detail native window + navigation", testWindowNativeStyleAndControllerNavigation),
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
