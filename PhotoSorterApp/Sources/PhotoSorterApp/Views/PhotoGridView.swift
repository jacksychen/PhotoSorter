import SwiftUI

struct PhotoGridView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedPhotoIndex: Int? = nil

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
                                    selectedPhotoIndex = index
                                }
                        }
                    }
                    .padding()
                }
            }
        }
        .sheet(item: sheetBinding) { wrapper in
            PhotoDetailView(
                photos: photos,
                currentIndex: wrapper.index
            )
            .frame(minWidth: 700, minHeight: 500)
        }
    }

    /// Bridge `selectedPhotoIndex` to an identifiable binding for `.sheet(item:)`.
    private var sheetBinding: Binding<IndexWrapper?> {
        Binding<IndexWrapper?>(
            get: {
                guard let index = selectedPhotoIndex else { return nil }
                return IndexWrapper(index: index)
            },
            set: { newValue in
                selectedPhotoIndex = newValue?.index
            }
        )
    }
}

/// A lightweight wrapper to make an `Int` index usable with `.sheet(item:)`.
private struct IndexWrapper: Identifiable {
    let index: Int
    var id: Int { index }
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
