import AppKit
import SwiftUI

public enum PhotoDetailKeyAction: Equatable {
    case previous
    case next
    case close

    public static func from(keyCode: UInt16) -> PhotoDetailKeyAction? {
        switch keyCode {
        case 123: return .previous // Left
        case 124: return .next // Right
        case 53: return .close // Esc
        default: return nil
        }
    }
}

final class PhotoDetailWindow: NSWindow {
    var onKeyAction: ((PhotoDetailKeyAction) -> Void)?

    override func keyDown(with event: NSEvent) {
        guard let action = PhotoDetailKeyAction.from(keyCode: event.keyCode) else {
            super.keyDown(with: event)
            return
        }

        onKeyAction?(action)
    }
}

public final class PhotoDetailWindowController: NSWindowController {
    private let state: PhotoDetailState

    public init(photos: [ManifestResult.Photo], currentIndex: Int) {
        self.state = PhotoDetailState(photos: photos, currentIndex: currentIndex)

        let rootView = PhotoDetailView(state: state)
        let hostingController = NSHostingController(rootView: rootView)

        let window = PhotoDetailWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.minSize = NSSize(width: 700, height: 500)
        window.title = state.currentPhoto.filename
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.onKeyAction = { [weak self] action in
            self?.handle(action)
        }

        state.onCurrentPhotoChanged = { [weak self] photo in
            self?.window?.title = photo.filename
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func update(photos: [ManifestResult.Photo], currentIndex: Int) {
        state.update(photos: photos, currentIndex: currentIndex)
    }

    public func handle(_ action: PhotoDetailKeyAction) {
        switch action {
        case .previous:
            state.navigatePrevious()
        case .next:
            state.navigateNext()
        case .close:
            window?.performClose(nil)
        }
    }
}
