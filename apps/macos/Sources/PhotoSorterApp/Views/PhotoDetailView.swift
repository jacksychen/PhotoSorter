import SwiftUI

@Observable
public final class PhotoDetailState {
    public private(set) var photos: [ManifestResult.Photo]
    public private(set) var currentIndex: Int

    public var onCurrentPhotoChanged: ((ManifestResult.Photo) -> Void)?

    public init(photos: [ManifestResult.Photo], currentIndex: Int) {
        precondition(!photos.isEmpty, "PhotoDetailState requires at least one photo")
        self.photos = photos
        self.currentIndex = Self.clampedIndex(currentIndex, count: photos.count)
    }

    public var currentPhoto: ManifestResult.Photo {
        photos[currentIndex]
    }

    public var canNavigatePrevious: Bool {
        currentIndex > 0
    }

    public var canNavigateNext: Bool {
        currentIndex < photos.count - 1
    }

    public func navigatePrevious() {
        guard canNavigatePrevious else { return }
        currentIndex -= 1
        onCurrentPhotoChanged?(currentPhoto)
    }

    public func navigateNext() {
        guard canNavigateNext else { return }
        currentIndex += 1
        onCurrentPhotoChanged?(currentPhoto)
    }

    public func update(photos: [ManifestResult.Photo], currentIndex: Int) {
        guard !photos.isEmpty else { return }
        self.photos = photos
        self.currentIndex = Self.clampedIndex(currentIndex, count: photos.count)
        onCurrentPhotoChanged?(currentPhoto)
    }

    private static func clampedIndex(_ index: Int, count: Int) -> Int {
        min(max(index, 0), max(count - 1, 0))
    }
}

struct PhotoDetailView: View {
    @Bindable var state: PhotoDetailState

    @State private var currentImage: NSImage? = nil

    var body: some View {
        VStack(spacing: 0) {
            imageCanvas
            Divider()
            footerBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: state.currentPhoto.id) {
            await loadFullImage()
        }
    }

    private var imageCanvas: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            Group {
                if let image = currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerBar: some View {
        HStack(spacing: 16) {
            Button {
                state.navigatePrevious()
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(!state.canNavigatePrevious)

            Button {
                state.navigateNext()
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .buttonStyle(.bordered)
            .disabled(!state.canNavigateNext)

            Text("\(state.currentIndex + 1) / \(state.photos.count)")
                .font(.headline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func loadFullImage() async {
        guard state.currentIndex >= 0, state.currentIndex < state.photos.count else { return }
        let path = state.photos[state.currentIndex].originalPath
        currentImage = nil

        let image = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOfFile: path)
        }.value

        if state.currentIndex < state.photos.count, state.photos[state.currentIndex].originalPath == path {
            currentImage = image
        }
    }
}
