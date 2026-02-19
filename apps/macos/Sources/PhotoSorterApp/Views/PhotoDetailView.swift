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
            ZStack {
                Color(nsColor: .underPageBackgroundColor)
                    .ignoresSafeArea()

                if let image = currentImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button {
                    state.navigatePrevious()
                } label: {
                    Label("Previous", systemImage: "chevron.left")
                }
                .disabled(!state.canNavigatePrevious)

                Button {
                    state.navigateNext()
                } label: {
                    Label("Next", systemImage: "chevron.right")
                }
                .disabled(!state.canNavigateNext)

                Spacer()

                Text(state.currentPhoto.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("\(state.currentIndex + 1) / \(state.photos.count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.bar)
        }
        .task(id: state.currentIndex) {
            await loadFullImage()
        }
    }

    private func loadFullImage() async {
        currentImage = nil

        guard state.currentIndex >= 0, state.currentIndex < state.photos.count else { return }
        let path = state.photos[state.currentIndex].originalPath

        let image = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOfFile: path)
        }.value

        if state.currentIndex < state.photos.count, state.photos[state.currentIndex].originalPath == path {
            currentImage = image
        }
    }
}
