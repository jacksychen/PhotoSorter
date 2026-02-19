import SwiftUI

struct PhotoGridView: View {
    @Environment(AppState.self) private var appState

    @State private var detailWindowController: PhotoDetailWindowController? = nil

    private var photos: [ManifestResult.Photo] {
        let clusters = appState.manifestResult?.clusters ?? []
        let index = appState.selectedClusterIndex
        guard index >= 0, index < clusters.count else { return [] }
        return clusters[index].photos
    }

    private let columns = [
        GridItem(.adaptive(minimum: 160), spacing: 12)
    ]

    var body: some View {
        Group {
            if photos.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo.on.rectangle",
                    description: Text("Select a cluster from the sidebar.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { index, photo in
                            PhotoCard(photo: photo)
                                .onTapGesture(count: 2) {
                                    openDetailWindow(at: index)
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .onDisappear {
            detailWindowController?.close()
            detailWindowController = nil
        }
    }

    private func openDetailWindow(at index: Int) {
        guard !photos.isEmpty else { return }

        if let controller = detailWindowController {
            controller.update(photos: photos, currentIndex: index)
            controller.show()
            return
        }

        let controller = PhotoDetailWindowController(photos: photos, currentIndex: index)
        detailWindowController = controller
        controller.show()
    }
}

// MARK: - PhotoCard

struct PhotoCard: View {
    let photo: ManifestResult.Photo

    @State private var thumbnailImage: NSImage? = nil

    /// Shared thumbnail loader for all cards.
    private static let loader = ThumbnailLoader()

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.15))
                    .aspectRatio(1, contentMode: .fit)

                if let image = thumbnailImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                        .clipped()
                        .cornerRadius(8)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(1, contentMode: .fit)

            Text(photo.filename)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)
        }
        .task(id: photo.originalPath) {
            thumbnailImage = await Self.loader.thumbnail(for: photo.originalPath)
        }
    }
}
