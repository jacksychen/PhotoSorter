import SwiftUI

private enum GridThumbnailPipeline {
    static let loader = ThumbnailLoader.shared

    static func sourcePath(for photo: ManifestResult.Photo) -> String {
        photo.originalPath
    }

    static func prebuildAll(
        photos: [ManifestResult.Photo],
        concurrency: Int,
        inputDir: URL?
    ) async {
        guard !photos.isEmpty, concurrency > 0 else { return }

        var orderedUniquePaths: [String] = []
        var orderedUniqueRawPaths: [String] = []
        orderedUniquePaths.reserveCapacity(photos.count)
        orderedUniqueRawPaths.reserveCapacity(photos.count)
        var seen: Set<String> = []

        for photo in photos {
            let path = sourcePath(for: photo)
            if seen.insert(path).inserted {
                orderedUniquePaths.append(path)
                if ThumbnailLoader.supportsDetailProxy(for: path) {
                    orderedUniqueRawPaths.append(path)
                }
            }
        }

        await runBatches(paths: orderedUniquePaths, concurrency: concurrency) { path in
            _ = await loader.thumbnail(for: path, inputDir: inputDir)
        }

        guard let inputDir, !orderedUniqueRawPaths.isEmpty else { return }

        await runBatches(paths: orderedUniqueRawPaths, concurrency: concurrency) { path in
            _ = await loader.detailProxyURL(for: path, inputDir: inputDir)
        }
    }

    private static func runBatches(
        paths: [String],
        concurrency: Int,
        work: @escaping @Sendable (String) async -> Void
    ) async {
        guard !paths.isEmpty, concurrency > 0 else { return }

        var start = 0
        while start < paths.count {
            if Task.isCancelled { return }
            let end = min(start + concurrency, paths.count)
            let chunk = Array(paths[start..<end])

            await withTaskGroup(of: Void.self) { group in
                for path in chunk {
                    group.addTask {
                        await work(path)
                    }
                }
            }

            start = end
        }
    }
}

private enum PhotoGridKeyAction: Equatable {
    case previous
    case next
    case previousRow
    case nextRow
    case toggleQuickLook
    case toggleMark

    static func from(keyCode: UInt16) -> Self? {
        switch keyCode {
        case 123: return .previous // Left
        case 124: return .next // Right
        case 126: return .previousRow // Up
        case 125: return .nextRow // Down
        case 49: return .toggleQuickLook // Space
        case 36, 76: return .toggleMark // Return / Keypad Enter
        default: return nil
        }
    }
}

struct PhotoGridView: View {
    @Environment(AppState.self) private var appState
    @Binding var photoCardMinimumWidth: CGFloat

    @State private var detailWindowController: PhotoDetailWindowController? = nil
    @State private var keyEventMonitor: Any? = nil
    @State private var thumbnailPrebuildTask: Task<Void, Never>? = nil
    @State private var pendingMarkPhotoPath: String? = nil
    @State private var markErrorMessage: String? = nil
    @State private var estimatedGridColumnCount: Int = 1
    @State private var visiblePhotoEntries: [PhotoEntry] = []

    private struct PhotoEntry: Identifiable {
        let clusterIndex: Int
        let photoIndex: Int
        let photo: ManifestResult.Photo

        var id: String { photo.id }
    }

    private var photoCount: Int {
        visiblePhotoEntries.count
    }

    private let gridSpacing: CGFloat = 12
    private let gridPadding: CGFloat = 16
    private let thumbnailPrebuildConcurrency: Int = 8

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: photoCardMinimumWidth), spacing: gridSpacing)]
    }

    var body: some View {
        let entries = visiblePhotoEntries
        let selectedIndex = normalizedSelectedPhotoIndex(photoCount: entries.count)

        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.on.rectangle",
                    description: Text("Select a filter from the sidebar.")
                )
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                let photo = entry.photo
                                PhotoCard(
                                    photo: photo,
                                    inputDir: appState.inputDir,
                                    isSelected: index == selectedIndex,
                                    isChecked: photo.isChecked,
                                    isMarking: pendingMarkPhotoPath == photo.originalPath,
                                    isToggleDisabled: pendingMarkPhotoPath != nil && pendingMarkPhotoPath != photo.originalPath,
                                    onToggleMarked: {
                                        toggleMarkedState(at: index)
                                    }
                                )
                                    .equatable()
                                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .onTapGesture(count: 2) {
                                        selectPhoto(at: index)
                                        openDetailWindow(at: index)
                                    }
                                    .onTapGesture {
                                        selectPhoto(at: index)
                                    }
                            }
                        }
                        .padding(gridPadding)
                    }
                    .onAppear {
                        updateEstimatedGridColumnCount(containerWidth: proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateEstimatedGridColumnCount(containerWidth: newWidth)
                    }
                    .onChange(of: photoCardMinimumWidth) { _, _ in
                        updateEstimatedGridColumnCount(containerWidth: proxy.size.width)
                    }
                }
            }
        }
        .onAppear {
            refreshVisiblePhotoEntries()
            normalizeSelectedPhotoIndexForCurrentSelection()
            scheduleThumbnailPrebuild()
            installKeyEventMonitorIfNeeded()
        }
        .onChange(of: appState.selectedSidebarSelection) { oldSelection, newSelection in
            // Reset selection to first photo whenever the filter changes,
            // not just when switching between two different clusters.
            if oldSelection != newSelection {
                setSelectedPhotoIndexIfNeeded(0)
            }
            refreshVisiblePhotoEntries()
            normalizeSelectedPhotoIndexForCurrentSelection()
            scheduleThumbnailPrebuild()
            syncDetailWindowToCurrentSelection()
        }
        .onChange(of: appState.manifestResult) { _, _ in
            refreshVisiblePhotoEntries()
            normalizeSelectedPhotoIndexForCurrentSelection()
            scheduleThumbnailPrebuild()
            syncDetailWindowToCurrentSelection()
        }
        .onChange(of: appState.selectedPhotoIndex) { _, _ in
            syncDetailWindowToSelectedPhoto()
        }
        .onDisappear {
            thumbnailPrebuildTask?.cancel()
            thumbnailPrebuildTask = nil
            removeKeyEventMonitor()
            detailWindowController?.close()
            detailWindowController = nil
        }
        .alert("Marking Failed", isPresented: markErrorPresentedBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(markErrorMessage ?? String(localized: "Unknown error", bundle: .appResources))
        }
    }

    private var markErrorPresentedBinding: Binding<Bool> {
        Binding(
            get: { markErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    markErrorMessage = nil
                }
            }
        )
    }

    private func openDetailWindow(at index: Int) {
        guard photoCount > 0 else { return }
        let photos = visiblePhotos()
        let targetIndex = min(max(index, 0), photos.count - 1)
        setSelectedPhotoIndexIfNeeded(targetIndex)

        if let controller = detailWindowController {
            controller.update(photos: photos, currentIndex: targetIndex, inputDir: appState.inputDir)
            controller.show()
            return
        }

        let controller = PhotoDetailWindowController(
            photos: photos,
            currentIndex: targetIndex,
            inputDir: appState.inputDir,
            onCurrentIndexChanged: { currentIndex in
                appState.selectedPhotoIndex = currentIndex
            },
            onToggleMarkRequested: { currentIndex in
                appState.selectedPhotoIndex = currentIndex
                toggleMarkedState(at: currentIndex)
            }
        )
        detailWindowController = controller
        controller.show()
    }

    private func syncDetailWindowToCurrentSelection() {
        guard let controller = detailWindowController else { return }
        guard photoCount > 0 else {
            controller.close()
            detailWindowController = nil
            return
        }

        let photos = visiblePhotos()
        let targetIndex = normalizedSelectedPhotoIndex()
        controller.update(photos: photos, currentIndex: targetIndex, inputDir: appState.inputDir)
    }

    private func selectPhoto(at index: Int) {
        guard photoCount > 0 else { return }
        setSelectedPhotoIndexIfNeeded(min(max(index, 0), photoCount - 1))
    }

    private func toggleMarkedState(at photoIndex: Int) {
        guard pendingMarkPhotoPath == nil else { return }
        guard let inputDir = appState.inputDir else {
            markErrorMessage = PhotoMarkingError.missingInputDirectory.localizedDescription
            return
        }
        guard let manifest = appState.manifestResult else {
            markErrorMessage = PhotoMarkingError.invalidSelection.localizedDescription
            return
        }

        guard photoIndex >= 0, photoIndex < visiblePhotoEntries.count else {
            markErrorMessage = PhotoMarkingError.invalidSelection.localizedDescription
            return
        }

        let entry = visiblePhotoEntries[photoIndex]
        pendingMarkPhotoPath = entry.photo.originalPath
        let sourcePathBeforeRename = entry.photo.originalPath

        Task {
            do {
                let updatedManifest = try await Task.detached(priority: .userInitiated) {
                    try PhotoMarkingService().toggleMark(
                        manifest: manifest,
                        inputDir: inputDir,
                        clusterIndex: entry.clusterIndex,
                        photoIndex: entry.photoIndex
                    )
                }.value

                let renamedPath = updatedManifest
                    .clusters[entry.clusterIndex]
                    .photos[entry.photoIndex]
                    .originalPath

                await GridThumbnailPipeline.loader.migrateEntry(
                    from: sourcePathBeforeRename,
                    to: renamedPath,
                    inputDir: inputDir
                )

                await MainActor.run {
                    appState.manifestResult = updatedManifest
                    pendingMarkPhotoPath = nil
                }
            } catch {
                await MainActor.run {
                    markErrorMessage = error.localizedDescription
                    pendingMarkPhotoPath = nil
                }
            }
        }
    }

    private func normalizedSelectedPhotoIndex() -> Int {
        normalizedSelectedPhotoIndex(photoCount: visiblePhotoEntries.count)
    }

    private func normalizedSelectedPhotoIndex(photoCount: Int) -> Int {
        guard photoCount > 0 else { return 0 }
        return min(max(appState.selectedPhotoIndex, 0), photoCount - 1)
    }

    private func normalizeSelectedPhotoIndexForCurrentSelection() {
        let normalized = normalizedSelectedPhotoIndex()
        if appState.selectedPhotoIndex != normalized {
            appState.selectedPhotoIndex = normalized
        }
    }

    private func syncDetailWindowToSelectedPhoto() {
        guard let controller = detailWindowController else { return }
        guard photoCount > 0 else { return }
        guard controller.window?.isVisible == true else { return }

        let targetIndex = normalizedSelectedPhotoIndex()
        guard controller.currentIndex != targetIndex else { return }
        controller.setCurrentIndex(targetIndex)
    }

    private func installKeyEventMonitorIfNeeded() {
        guard keyEventMonitor == nil else { return }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard let action = resolvedGridKeyAction(for: event) else {
                return event
            }

            handleGridKeyAction(action)
            return nil
        }
    }

    private func removeKeyEventMonitor() {
        if let keyEventMonitor {
            NSEvent.removeMonitor(keyEventMonitor)
            self.keyEventMonitor = nil
        }
    }

    private func resolvedGridKeyAction(for event: NSEvent) -> PhotoGridKeyAction? {
        guard let action = PhotoGridKeyAction.from(keyCode: event.keyCode) else { return nil }
        guard NSApp.isActive else { return nil }
        guard appState.phase == .results else { return nil }

        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if !event.modifierFlags.intersection(blockedModifiers).isEmpty {
            return nil
        }

        if detailWindowController?.window === NSApp.keyWindow {
            return nil
        }

        return action
    }

    private func handleGridKeyAction(_ action: PhotoGridKeyAction) {
        switch action {
        case .previous:
            moveSelection(offset: -1)
        case .next:
            moveSelection(offset: 1)
        case .previousRow:
            moveSelection(offset: -max(estimatedGridColumnCount, 1))
        case .nextRow:
            moveSelection(offset: max(estimatedGridColumnCount, 1))
        case .toggleQuickLook:
            toggleQuickLookFromSelection()
        case .toggleMark:
            guard photoCount > 0 else {
                NSSound.beep()
                return
            }
            toggleMarkedState(at: normalizedSelectedPhotoIndex())
        }
    }

    private func moveSelection(offset: Int) {
        guard photoCount > 0 else {
            NSSound.beep()
            return
        }

        let currentIndex = normalizedSelectedPhotoIndex()
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0, targetIndex < photoCount else {
            NSSound.beep()
            return
        }
        setSelectedPhotoIndexIfNeeded(targetIndex)
    }

    private func updateEstimatedGridColumnCount(containerWidth: CGFloat) {
        let availableWidth = max(containerWidth - (gridPadding * 2), photoCardMinimumWidth)
        let slot = photoCardMinimumWidth + gridSpacing
        let count = Int((availableWidth + gridSpacing) / slot)
        estimatedGridColumnCount = max(count, 1)
    }

    private func toggleQuickLookFromSelection() {
        guard photoCount > 0 else {
            NSSound.beep()
            return
        }

        let targetIndex = normalizedSelectedPhotoIndex()
        setSelectedPhotoIndexIfNeeded(targetIndex)

        if detailWindowController?.window?.isVisible == true {
            detailWindowController?.close()
            return
        }

        openDetailWindow(at: targetIndex)
    }

    private func visiblePhotos() -> [ManifestResult.Photo] {
        visiblePhotoEntries.map(\.photo)
    }

    private func setSelectedPhotoIndexIfNeeded(_ index: Int) {
        if appState.selectedPhotoIndex != index {
            appState.selectedPhotoIndex = index
        }
    }

    private func refreshVisiblePhotoEntries() {
        let clusters = appState.manifestResult?.clusters ?? []
        visiblePhotoEntries = buildPhotoEntries(
            from: clusters,
            selection: appState.selectedSidebarSelection
        )
    }

    private func scheduleThumbnailPrebuild() {
        thumbnailPrebuildTask?.cancel()
        thumbnailPrebuildTask = nil

        let photos = visiblePhotos()
        guard !photos.isEmpty else { return }

        let concurrency = thumbnailPrebuildConcurrency

        thumbnailPrebuildTask = Task(priority: .utility) {
            await GridThumbnailPipeline.prebuildAll(
                photos: photos,
                concurrency: concurrency,
                inputDir: appState.inputDir
            )
        }
    }

    private func buildPhotoEntries(
        from clusters: [ManifestResult.Cluster],
        selection: SidebarSelection
    ) -> [PhotoEntry] {
        switch selection {
        case .allPhotos:
            return clusters.enumerated().flatMap { clusterIndex, cluster in
                cluster.photos.enumerated().map { photoIndex, photo in
                    PhotoEntry(clusterIndex: clusterIndex, photoIndex: photoIndex, photo: photo)
                }
            }
        case .checkedPhotos:
            return clusters.enumerated().flatMap { clusterIndex, cluster in
                cluster.photos.enumerated().compactMap { photoIndex, photo in
                    guard photo.isChecked else { return nil }
                    return PhotoEntry(clusterIndex: clusterIndex, photoIndex: photoIndex, photo: photo)
                }
            }
        case .cluster(let clusterIndex):
            guard clusterIndex >= 0, clusterIndex < clusters.count else { return [] }
            return clusters[clusterIndex].photos.enumerated().map { photoIndex, photo in
                PhotoEntry(clusterIndex: clusterIndex, photoIndex: photoIndex, photo: photo)
            }
        }
    }
}

// MARK: - PhotoCard

struct PhotoCard: View, Equatable {
    let photo: ManifestResult.Photo
    let inputDir: URL?
    let isSelected: Bool
    let isChecked: Bool
    let isMarking: Bool
    let isToggleDisabled: Bool
    let onToggleMarked: () -> Void

    @State private var thumbnailImage: NSImage? = nil
    @State private var currentThumbnailRequestPath: String? = nil
    @State private var thumbnailAspectRatio: CGFloat = 4.0 / 3.0

    /// Shared thumbnail loader for all cards.
    private static let loader = GridThumbnailPipeline.loader

    private var thumbnailSourcePath: String {
        GridThumbnailPipeline.sourcePath(for: photo)
    }

    static func == (lhs: PhotoCard, rhs: PhotoCard) -> Bool {
        lhs.photo.id == rhs.photo.id &&
        lhs.photo.filename == rhs.photo.filename &&
        lhs.isSelected == rhs.isSelected &&
        lhs.isChecked == rhs.isChecked &&
        lhs.isMarking == rhs.isMarking &&
        lhs.isToggleDisabled == rhs.isToggleDisabled
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))

                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(thumbnailAspectRatio, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.primary.opacity(0.08),
                        lineWidth: isSelected ? 3 : 1
                    )
            )
            .overlay(alignment: .topLeading) {
                Button {
                    onToggleMarked()
                } label: {
                    if isMarking {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isChecked ? Color.accentColor : Color.white)
                            .frame(width: 18, height: 18)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isMarking || isToggleDisabled)
                .shadow(color: .black.opacity(0.32), radius: 1.1, x: 0, y: 1)
                .padding(6)
            }

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .task(id: thumbnailSourcePath) {
            let requestPath = thumbnailSourcePath
            currentThumbnailRequestPath = requestPath
            thumbnailImage = nil

            let image = await Self.loader.thumbnail(for: requestPath, inputDir: inputDir)
            guard !Task.isCancelled else { return }
            guard currentThumbnailRequestPath == requestPath else { return }
            if let image {
                thumbnailAspectRatio = normalizedAspectRatio(for: image)
            }
            thumbnailImage = image
        }
    }

    private func normalizedAspectRatio(for image: NSImage) -> CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 4.0 / 3.0 }
        let ratio = size.width / size.height
        return min(max(ratio, 0.2), 8.0)
    }
}
