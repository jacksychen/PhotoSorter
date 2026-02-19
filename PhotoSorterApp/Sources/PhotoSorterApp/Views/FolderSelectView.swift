import SwiftUI
import UniformTypeIdentifiers

struct FolderSelectView: View {
    @Environment(AppState.self) private var appState

    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tint)

            Text("PhotoSorter")
                .font(.largeTitle)
                .bold()

            Text("Reorder travel photos by visual similarity")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Choose a folder containing your photos to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Button("Choose Folder...") {
                chooseFolder()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 3, dash: [8])
                )
                .padding(16)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Folder selection

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing photos"
        if panel.runModal() == .OK, let url = panel.url {
            handleFolder(url)
        }
    }

    // MARK: - Drop handling

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
            else { return }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return }

            DispatchQueue.main.async {
                handleFolder(url)
            }
        }

        return true
    }

    // MARK: - Handle selected folder

    private func handleFolder(_ url: URL) {
        appState.inputDir = url

        let manifestURL = url.appendingPathComponent("manifest.json")

        if FileManager.default.fileExists(atPath: manifestURL.path) {
            if let data = try? Data(contentsOf: manifestURL),
               let manifest = try? JSONDecoder().decode(ManifestResult.self, from: data) {
                appState.manifestResult = manifest
                extractParameters(from: manifest)
                appState.selectedClusterIndex = 0
                appState.phase = .results
            } else {
                // Manifest exists but is corrupt — warn user and proceed to parameters.
                appState.errorMessage = "Existing manifest.json could not be read and will be overwritten."
                appState.phase = .parameters
            }
        } else {
            appState.phase = .parameters
        }
    }

    /// Populate `appState.parameters` from a previously saved manifest.
    private func extractParameters(from manifest: ManifestResult) {
        guard let mp = manifest.parameters else { return }

        var params = PipelineParameters.defaults

        if let deviceStr = mp.device,
           let device = PipelineParameters.DeviceOption(rawValue: deviceStr) {
            params.device = device
        }

        if let batchSize = mp.batchSize {
            params.batchSize = batchSize
        }

        if let poolingStr = mp.pooling,
           let pooling = PipelineParameters.PoolingOption(rawValue: poolingStr) {
            params.pooling = pooling
        }

        if let threshold = mp.distanceThreshold {
            params.distanceThreshold = threshold
        }

        if let linkageStr = mp.linkage,
           let linkage = PipelineParameters.LinkageOption(rawValue: linkageStr) {
            params.linkage = linkage
        }

        if let tw = mp.temporalWeight {
            params.temporalWeight = tw
        }

        appState.parameters = params
    }
}
