import SwiftUI

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

    @State private var detailWindowController: PhotoDetailWindowController? = nil
    @State private var keyEventMonitor: Any? = nil
    @State private var pendingMarkPhotoPath: String? = nil
    @State private var markErrorMessage: String? = nil
    @State private var estimatedGridColumnCount: Int = 1

    private struct PhotoEntry: Identifiable {
        let clusterIndex: Int
        let photoIndex: Int
        let photo: ManifestResult.Photo

        var id: String { photo.id }
    }

    private var clusters: [ManifestResult.Cluster] {
        appState.manifestResult?.clusters ?? []
    }

    private var photoEntries: [PhotoEntry] {
        switch appState.selectedSidebarSelection {
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

    private var photos: [ManifestResult.Photo] {
        photoEntries.map(\.photo)
    }

    private let cardMinimumWidth: CGFloat = 160
    private let gridSpacing: CGFloat = 12
    private let gridPadding: CGFloat = 16

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cardMinimumWidth), spacing: gridSpacing)]
    }

    var body: some View {
        let entries = photoEntries
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
                                    isSelected: index == selectedIndex,
                                    isChecked: photo.isChecked,
                                    isMarking: pendingMarkPhotoPath == photo.originalPath,
                                    isToggleDisabled: pendingMarkPhotoPath != nil && pendingMarkPhotoPath != photo.originalPath,
                                    onToggleMarked: {
                                        toggleMarkedState(at: index)
                                    }
                                )
                                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .onTapGesture {
                                        selectPhoto(at: index)
                                    }
                                    .onTapGesture(count: 2) {
                                        selectPhoto(at: index)
                                        openDetailWindow(at: index)
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
                }
            }
        }
        .onAppear {
            normalizeSelectedPhotoIndexForCurrentSelection()
            installKeyEventMonitorIfNeeded()
        }
        .onChange(of: appState.selectedSidebarSelection) { oldSelection, newSelection in
            if shouldResetSelectionOnClusterSwitch(
                oldSelection: oldSelection,
                newSelection: newSelection
            ) {
                appState.selectedPhotoIndex = 0
            }
            normalizeSelectedPhotoIndexForCurrentSelection()
            syncDetailWindowToCurrentSelection()
        }
        .onChange(of: appState.selectedPhotoIndex) { _, _ in
            syncDetailWindowToSelectedPhoto()
        }
        .onDisappear {
            removeKeyEventMonitor()
            detailWindowController?.close()
            detailWindowController = nil
        }
        .alert("Marking Failed", isPresented: markErrorPresentedBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(markErrorMessage ?? "Unknown error")
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
        guard !photos.isEmpty else { return }
        let targetIndex = min(max(index, 0), photos.count - 1)
        appState.selectedPhotoIndex = targetIndex

        if let controller = detailWindowController {
            controller.update(photos: photos, currentIndex: targetIndex)
            controller.show()
            return
        }

        let controller = PhotoDetailWindowController(
            photos: photos,
            currentIndex: targetIndex,
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
        guard !photos.isEmpty else {
            controller.close()
            detailWindowController = nil
            return
        }

        let targetIndex = normalizedSelectedPhotoIndex()
        controller.update(photos: photos, currentIndex: targetIndex)
    }

    private func selectPhoto(at index: Int) {
        guard !photos.isEmpty else { return }
        appState.selectedPhotoIndex = min(max(index, 0), photos.count - 1)
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

        guard photoIndex >= 0, photoIndex < photoEntries.count else {
            markErrorMessage = PhotoMarkingError.invalidSelection.localizedDescription
            return
        }

        let entry = photoEntries[photoIndex]
        pendingMarkPhotoPath = entry.photo.originalPath

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

                await MainActor.run {
                    appState.manifestResult = updatedManifest
                    normalizeSelectedPhotoIndexForCurrentSelection()
                    syncDetailWindowToCurrentSelection()
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
        normalizedSelectedPhotoIndex(photoCount: photoEntries.count)
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

    private func shouldResetSelectionOnClusterSwitch(
        oldSelection: SidebarSelection,
        newSelection: SidebarSelection
    ) -> Bool {
        guard case .cluster(let oldClusterIndex) = oldSelection else { return false }
        guard case .cluster(let newClusterIndex) = newSelection else { return false }
        return oldClusterIndex != newClusterIndex
    }

    private func syncDetailWindowToSelectedPhoto() {
        guard let controller = detailWindowController else { return }
        guard !photos.isEmpty else { return }
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
            guard !photos.isEmpty else {
                NSSound.beep()
                return
            }
            toggleMarkedState(at: normalizedSelectedPhotoIndex())
        }
    }

    private func moveSelection(offset: Int) {
        guard !photos.isEmpty else {
            NSSound.beep()
            return
        }

        let currentIndex = normalizedSelectedPhotoIndex()
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0, targetIndex < photos.count else {
            NSSound.beep()
            return
        }
        appState.selectedPhotoIndex = targetIndex
    }

    private func updateEstimatedGridColumnCount(containerWidth: CGFloat) {
        let availableWidth = max(containerWidth - (gridPadding * 2), cardMinimumWidth)
        let slot = cardMinimumWidth + gridSpacing
        let count = Int((availableWidth + gridSpacing) / slot)
        estimatedGridColumnCount = max(count, 1)
    }

    private func toggleQuickLookFromSelection() {
        guard !photos.isEmpty else {
            NSSound.beep()
            return
        }

        let targetIndex = normalizedSelectedPhotoIndex()
        appState.selectedPhotoIndex = targetIndex

        if detailWindowController?.window?.isVisible == true {
            detailWindowController?.close()
            return
        }

        openDetailWindow(at: targetIndex)
    }
}

// MARK: - PhotoCard

struct PhotoCard: View {
    let photo: ManifestResult.Photo
    let isSelected: Bool
    let isChecked: Bool
    let isMarking: Bool
    let isToggleDisabled: Bool
    let onToggleMarked: () -> Void

    @State private var thumbnailImage: NSImage? = nil

    /// Shared thumbnail loader for all cards.
    private static let loader = ThumbnailLoader()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.12))
                    .aspectRatio(1, contentMode: .fit)

                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    ProgressView()
                }
            }
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
            .aspectRatio(1, contentMode: .fit)

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .task(id: photo.originalPath) {
            thumbnailImage = await Self.loader.thumbnail(for: photo.originalPath)
        }
    }
}
