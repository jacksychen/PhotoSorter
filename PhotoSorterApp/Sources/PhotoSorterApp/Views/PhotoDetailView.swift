import SwiftUI

struct PhotoDetailView: View {
    let photos: [ManifestResult.Photo]

    @State var currentIndex: Int
    @State private var currentImage: NSImage? = nil

    @Environment(\.dismiss) private var dismiss

    private var currentPhoto: ManifestResult.Photo {
        photos[currentIndex]
    }

    var body: some View {
        ZStack {
            // Dark background
            Color.black.ignoresSafeArea()

            // Full-size image
            if let image = currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }

            // Bottom info bar
            VStack {
                Spacer()

                HStack {
                    Text(currentPhoto.filename)
                        .font(.headline)
                        .foregroundStyle(.white)

                    Spacer()

                    Text("\(currentIndex + 1) / \(photos.count)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding()
                .background(.black.opacity(0.6))
            }

            // Navigation arrows overlay
            HStack {
                // Left arrow area
                Button {
                    navigatePrevious()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.3))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(currentIndex > 0 ? 1 : 0.3)
                .disabled(currentIndex <= 0)
                .padding(.leading, 16)

                Spacer()

                // Right arrow area
                Button {
                    navigateNext()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.title)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.3))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(currentIndex < photos.count - 1 ? 1 : 0.3)
                .disabled(currentIndex >= photos.count - 1)
                .padding(.trailing, 16)
            }
        }
        .onKeyPress(.leftArrow) {
            navigatePrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            navigateNext()
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .task(id: currentIndex) {
            await loadFullImage()
        }
    }

    // MARK: - Navigation

    private func navigatePrevious() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func navigateNext() {
        guard currentIndex < photos.count - 1 else { return }
        currentIndex += 1
    }

    // MARK: - Image loading

    private func loadFullImage() async {
        currentImage = nil
        guard currentIndex >= 0, currentIndex < photos.count else { return }
        let path = photos[currentIndex].originalPath
        // Load off main thread to avoid blocking UI with large images.
        let image = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOfFile: path)
        }.value
        // Only update if still on the same photo.
        if currentIndex < photos.count, photos[currentIndex].originalPath == path {
            currentImage = image
        }
    }
}
