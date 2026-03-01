import SwiftUI

struct ResultView: View {
    @State private var photoCardMinimumWidth: CGFloat = 160

    private let minimumPreviewCardWidth: CGFloat = 100
    private let maximumPreviewCardWidth: CGFloat = 280
    private let previewCardWidthStep: CGFloat = 20

    var body: some View {
        NavigationSplitView {
            ClusterSidebar()
        } detail: {
            PhotoGridView(photoCardMinimumWidth: $photoCardMinimumWidth)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                photoPreviewSizeToolbarControls
            }
        }
    }

    private var photoPreviewSizeToolbarControls: some View {
        HStack(spacing: 0) {
            photoPreviewSizeButton(
                systemName: "minus",
                helpText: "Decrease preview card size",
                isDisabled: photoCardMinimumWidth <= minimumPreviewCardWidth,
                action: decreasePhotoPreviewCardSize
            )

            Rectangle()
                .fill(.white.opacity(0.20))
                .frame(width: 1, height: 18)
                .padding(.vertical, 4)

            photoPreviewSizeButton(
                systemName: "plus",
                helpText: "Increase preview card size",
                isDisabled: photoCardMinimumWidth >= maximumPreviewCardWidth,
                action: increasePhotoPreviewCardSize
            )
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.35), .white.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.9
                )
        }
        .shadow(color: .black.opacity(0.10), radius: 8, x: 0, y: 3)
    }

    private func photoPreviewSizeButton(
        systemName: String,
        helpText: LocalizedStringKey,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(isDisabled ? Color.secondary.opacity(0.55) : Color.primary)
        .help(Text(helpText))
        .disabled(isDisabled)
    }

    private func decreasePhotoPreviewCardSize() {
        adjustPhotoPreviewCardSize(by: -previewCardWidthStep)
    }

    private func increasePhotoPreviewCardSize() {
        adjustPhotoPreviewCardSize(by: previewCardWidthStep)
    }

    private func adjustPhotoPreviewCardSize(by delta: CGFloat) {
        let newValue = min(
            max(photoCardMinimumWidth + delta, minimumPreviewCardWidth),
            maximumPreviewCardWidth
        )
        guard newValue != photoCardMinimumWidth else { return }
        photoCardMinimumWidth = newValue
    }
}
