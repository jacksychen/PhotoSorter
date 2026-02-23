import AppKit
import QuickLookUI

public enum PhotoDetailKeyAction: Equatable {
    case previous
    case next
    case close
    case toggleMark

    public static func from(keyCode: UInt16) -> PhotoDetailKeyAction? {
        switch keyCode {
        case 123, 126: return .previous // Left / Up
        case 124, 125: return .next // Right / Down
        case 53, 49: return .close // Esc / Space (Quick Look style)
        case 36, 76: return .toggleMark // Return / Keypad Enter
        default: return nil
        }
    }
}

private final class PhotoPreviewItem: NSObject, QLPreviewItem {
    let originalURL: URL
    let isRaw: Bool
    var previewItemURL: URL?
    let previewItemTitle: String?

    init(photo: ManifestResult.Photo, previewURL: URL?, isRaw: Bool) {
        let originalURL = URL(fileURLWithPath: photo.originalPath)
        self.originalURL = originalURL
        self.isRaw = isRaw
        self.previewItemURL = previewURL ?? originalURL
        self.previewItemTitle = photo.filename
        super.init()
    }
}

@MainActor
public final class PhotoDetailWindowController: NSObject {
    private var previewItems: [PhotoPreviewItem]
    private var selectedIndex: Int
    private var inputDir: URL?
    private let onCurrentIndexChanged: ((Int) -> Void)?
    private let onToggleMarkRequested: ((Int) -> Void)?
    private weak var panel: QLPreviewPanel?
    private var keyEventMonitor: Any?
    private var panelIndexObservation: NSKeyValueObservation?
    private var panelCloseObserver: NSObjectProtocol?
    private var previewWarmupTask: Task<Void, Never>?

    private let previewPrefetchRadius: Int = 3

    public var currentIndex: Int {
        selectedIndex
    }

    public var window: NSWindow? {
        panel
    }

    public init(
        photos: [ManifestResult.Photo],
        currentIndex: Int,
        inputDir: URL? = nil,
        onCurrentIndexChanged: ((Int) -> Void)? = nil,
        onToggleMarkRequested: ((Int) -> Void)? = nil
    ) {
        precondition(!photos.isEmpty, "PhotoDetailWindowController requires at least one photo")
        self.inputDir = inputDir
        self.previewItems = Self.makePreviewItems(from: photos, inputDir: inputDir)
        self.selectedIndex = Self.clampedIndex(currentIndex, count: photos.count)
        self.onCurrentIndexChanged = onCurrentIndexChanged
        self.onToggleMarkRequested = onToggleMarkRequested
        super.init()
        installKeyMonitor()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }

        panelIndexObservation?.invalidate()
        panelIndexObservation = nil

        if let panelCloseObserver {
            NotificationCenter.default.removeObserver(panelCloseObserver)
            self.panelCloseObserver = nil
        }

        previewWarmupTask?.cancel()
        previewWarmupTask = nil
    }

    public func show() {
        guard !previewItems.isEmpty else { return }
        guard let panel = QLPreviewPanel.shared() else { return }
        self.panel = panel
        attachToPanel(panel)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])

        panel.reloadData()
        panel.currentPreviewItemIndex = selectedIndex
        panel.makeKeyAndOrderFront(nil)
        applyBestAvailablePreviewURL(at: selectedIndex)
        schedulePreviewWarmup(around: selectedIndex)
    }

    public func update(photos: [ManifestResult.Photo], currentIndex: Int, inputDir: URL? = nil) {
        guard !photos.isEmpty else { return }
        self.inputDir = inputDir
        let shouldReloadPreviewItems = needsPreviewItemsReload(with: photos)
        if shouldReloadPreviewItems {
            previewItems = Self.makePreviewItems(from: photos, inputDir: inputDir)
        }
        setCurrentIndex(currentIndex)

        guard shouldReloadPreviewItems else { return }
        guard let panel else { return }
        guard panel.isVisible else { return }
        panel.reloadData()
        if panel.currentPreviewItemIndex != selectedIndex {
            panel.currentPreviewItemIndex = selectedIndex
        }
        schedulePreviewWarmup(around: selectedIndex)
    }

    public func setCurrentIndex(_ currentIndex: Int) {
        guard !previewItems.isEmpty else { return }
        let targetIndex = Self.clampedIndex(currentIndex, count: previewItems.count)
        guard targetIndex != selectedIndex else {
            if let panel, panel.isVisible, panel.currentPreviewItemIndex != targetIndex {
                panel.currentPreviewItemIndex = targetIndex
            }
            return
        }

        selectedIndex = targetIndex
        applyBestAvailablePreviewURL(at: targetIndex)
        if let panel, panel.isVisible, panel.currentPreviewItemIndex != targetIndex {
            panel.currentPreviewItemIndex = targetIndex
        }
        schedulePreviewWarmup(around: targetIndex)
    }

    public func handle(_ action: PhotoDetailKeyAction) {
        switch action {
        case .previous:
            movePhoto(offset: -1)
        case .next:
            movePhoto(offset: 1)
        case .close:
            close()
        case .toggleMark:
            onToggleMarkRequested?(selectedIndex)
        }
    }

    public func close() {
        guard let panel else { return }

        if panel.isVisible {
            panel.close()
            handlePanelClosed()
            return
        }

        // Ensure stale panel references and observers are cleaned even if already closed.
        handlePanelClosed()
    }

    private func movePhoto(offset: Int) {
        guard !previewItems.isEmpty else { return }
        let target = selectedIndex + offset
        if target >= 0, target < previewItems.count {
            selectedIndex = target
            applyBestAvailablePreviewURL(at: target)
            if let panel, panel.currentPreviewItemIndex != selectedIndex {
                panel.currentPreviewItemIndex = selectedIndex
            }
            onCurrentIndexChanged?(selectedIndex)
            schedulePreviewWarmup(around: selectedIndex)
            return
        }
        // Keep keyboard navigation scoped to the current cluster.
        NSSound.beep()
    }

    private func installKeyMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            guard shouldHandlePanelKeyEvent(event) else {
                return event
            }

            guard let action = PhotoDetailKeyAction.from(keyCode: event.keyCode) else {
                return event
            }

            handle(action)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func shouldHandlePanelKeyEvent(_ event: NSEvent) -> Bool {
        guard let panel else { return false }
        guard panel.isVisible else { return false }
        guard !panel.isMiniaturized else { return false }
        guard NSApp.isActive else { return false }
        guard NSApp.keyWindow === panel || NSApp.mainWindow === panel else { return false }

        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        return event.modifierFlags.intersection(blockedModifiers).isEmpty
    }

    private func attachToPanel(_ panel: QLPreviewPanel) {
        panel.dataSource = self
        panel.delegate = self

        if let panelCloseObserver {
            NotificationCenter.default.removeObserver(panelCloseObserver)
            self.panelCloseObserver = nil
        }
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handlePanelClosed()
            }
        }

        panelIndexObservation?.invalidate()
        panelIndexObservation = panel.observe(\.currentPreviewItemIndex, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let panel = self.panel else { return }
                self.syncSelectionFromPanel(panel, panel.currentPreviewItemIndex)
            }
        }
    }

    private func syncSelectionFromPanel(_ panel: QLPreviewPanel, _ panelIndex: Int) {
        guard panel === self.panel else { return }
        guard panel.isVisible else { return }
        guard !panel.isMiniaturized else { return }
        guard panelIndex != NSNotFound else { return }
        let target = Self.clampedIndex(panelIndex, count: previewItems.count)
        guard target != selectedIndex else { return }
        selectedIndex = target
        onCurrentIndexChanged?(selectedIndex)
        applyBestAvailablePreviewURL(at: target)
        schedulePreviewWarmup(around: target)
    }

    private func handlePanelClosed() {
        previewWarmupTask?.cancel()
        previewWarmupTask = nil
        detachFromPanelIfNeeded()
        panel = nil
    }

    private func detachFromPanelIfNeeded() {
        panelIndexObservation?.invalidate()
        panelIndexObservation = nil

        if let panelCloseObserver {
            NotificationCenter.default.removeObserver(panelCloseObserver)
            self.panelCloseObserver = nil
        }

        guard let panel else { return }
        panel.dataSource = nil
        panel.delegate = nil
    }

    private func needsPreviewItemsReload(with photos: [ManifestResult.Photo]) -> Bool {
        guard previewItems.count == photos.count else { return true }

        for (index, photo) in photos.enumerated() {
            let item = previewItems[index]
            if item.originalURL.path != photo.originalPath || item.previewItemTitle != photo.filename {
                return true
            }
        }

        return false
    }

    private static func makePreviewItems(from photos: [ManifestResult.Photo], inputDir: URL?) -> [PhotoPreviewItem] {
        photos.map { photo in
            let isRaw = ThumbnailLoader.supportsDetailProxy(for: photo.originalPath)
            let originalURL = URL(fileURLWithPath: photo.originalPath)
            let previewURL: URL?
            if isRaw {
                previewURL = ThumbnailLoader.cachedDetailProxyURLIfFresh(for: photo.originalPath, inputDir: inputDir)
                    ?? ThumbnailLoader.cachedGridThumbURLIfFresh(for: photo.originalPath, inputDir: inputDir)
                    ?? originalURL
            } else {
                previewURL = originalURL
            }
            return PhotoPreviewItem(photo: photo, previewURL: previewURL, isRaw: isRaw)
        }
    }

    private func applyBestAvailablePreviewURL(at index: Int) {
        guard index >= 0, index < previewItems.count else { return }
        let item = previewItems[index]
        let bestURL = bestAvailablePreviewURL(for: item)
        guard item.previewItemURL?.path != bestURL.path else { return }
        item.previewItemURL = bestURL
        refreshPanelIfShowingItem(at: index)
    }

    private func bestAvailablePreviewURL(for item: PhotoPreviewItem) -> URL {
        guard item.isRaw else { return item.originalURL }
        if let inputDir {
            if let detailURL = ThumbnailLoader.cachedDetailProxyURLIfFresh(for: item.originalURL.path, inputDir: inputDir) {
                return detailURL
            }
            if let gridURL = ThumbnailLoader.cachedGridThumbURLIfFresh(for: item.originalURL.path, inputDir: inputDir) {
                return gridURL
            }
        }
        return item.originalURL
    }

    private func schedulePreviewWarmup(around centerIndex: Int) {
        guard centerIndex >= 0, centerIndex < previewItems.count else { return }
        previewWarmupTask?.cancel()
        previewWarmupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.warmPreviewProxies(around: centerIndex)
        }
    }

    private func warmPreviewProxies(around centerIndex: Int) async {
        guard let inputDir else { return }

        let indices = previewWarmupIndices(around: centerIndex)
        let loader = ThumbnailLoader.shared

        for index in indices {
            if Task.isCancelled { return }
            guard index >= 0, index < previewItems.count else { continue }
            let item = previewItems[index]
            guard item.isRaw else { continue }

            if index == centerIndex,
               ThumbnailLoader.cachedGridThumbURLIfFresh(for: item.originalURL.path, inputDir: inputDir) == nil {
                _ = await loader.thumbnail(for: item.originalURL.path, inputDir: inputDir)
                guard !Task.isCancelled else { return }
                applyBestAvailablePreviewURL(at: index)
            }

            if ThumbnailLoader.cachedDetailProxyURLIfFresh(for: item.originalURL.path, inputDir: inputDir) == nil {
                _ = await loader.detailProxyURL(for: item.originalURL.path, inputDir: inputDir)
                guard !Task.isCancelled else { return }
                applyBestAvailablePreviewURL(at: index)
            }
        }
    }

    private func previewWarmupIndices(around centerIndex: Int) -> [Int] {
        var indices: [Int] = [centerIndex]
        if previewPrefetchRadius <= 0 { return indices }
        for offset in 1...previewPrefetchRadius {
            let next = centerIndex + offset
            if next < previewItems.count {
                indices.append(next)
            }
            let previous = centerIndex - offset
            if previous >= 0 {
                indices.append(previous)
            }
        }
        return indices
    }

    private func refreshPanelIfShowingItem(at index: Int) {
        guard let panel else { return }
        guard panel.isVisible else { return }
        guard panel.currentPreviewItemIndex == index else { return }
        panel.reloadData()
        if panel.currentPreviewItemIndex != index {
            panel.currentPreviewItemIndex = index
        }
    }

    private static func clampedIndex(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}

extension PhotoDetailWindowController: QLPreviewPanelDataSource {
    nonisolated public func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated public func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            guard index >= 0, index < previewItems.count else { return nil }
            return previewItems[index]
        }
    }
}

extension PhotoDetailWindowController: QLPreviewPanelDelegate {}
