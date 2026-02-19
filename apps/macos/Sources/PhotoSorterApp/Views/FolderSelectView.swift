import SwiftUI
import UniformTypeIdentifiers

struct FolderSelectView: View {
    @Environment(AppState.self) private var appState

    @State private var isDropTargeted = false
    @State private var isFolderImporterPresented = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Main content
                VStack(spacing: 0) {
                    Spacer()

                    // Hero
                    VStack(spacing: 16) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 52, weight: .thin))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)

                        VStack(spacing: 6) {
                            Text("Welcome")
                                .font(.title.weight(.semibold))

                            Text("Organize photos by visual similarity")
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()
                        .frame(height: 36)

                    // Drop zone with Liquid Glass
                    dropZone
                        .frame(maxWidth: 400)

                    Spacer()
                        .frame(height: 24)

                    // Primary action
                    Button {
                        isFolderImporterPresented = true
                    } label: {
                        Label("Choose Folder…", systemImage: "folder")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut("o", modifiers: [.command])

                    // Selected folder indicator
                    if let inputDir = appState.inputDir {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            PathControlView(url: inputDir)
                                .frame(maxWidth: 340)
                        }
                        .font(.subheadline)
                        .padding(.top, 12)
                    }

                    Spacer()
                }
                .padding(.horizontal, 40)

                // Full-window drag overlay
                if isDropTargeted {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)

                        VStack(spacing: 12) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(Color.accentColor)

                            Text("Release to open")
                                .font(.title3.weight(.medium))
                        }
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
            .navigationTitle("PhotoSorter")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isFolderImporterPresented = true
                    } label: {
                        Label("Open…", systemImage: "folder")
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else { return }
            handleFolder(url)
        }
    }

    // MARK: - Drop zone

    @ViewBuilder
    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)

            Text("Drop a folder here")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
        appState.errorMessage = nil

        let manifestURL = url.appendingPathComponent("manifest.json")
        if let manifest = loadManifest(from: manifestURL) {
            applyExistingManifest(manifest)
        } else if FileManager.default.fileExists(atPath: manifestURL.path) {
            appState.errorMessage = "Existing manifest.json could not be read and will be overwritten."
            appState.phase = .parameters
        } else {
            appState.phase = .parameters
        }
    }

    private func loadManifest(from url: URL) -> ManifestResult? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(ManifestResult.self, from: data)
    }

    private func applyExistingManifest(_ manifest: ManifestResult) {
        appState.manifestResult = manifest
        extractParameters(from: manifest)
        appState.selectedSidebarSelection = .allPhotos
        appState.selectedPhotoIndex = 0
        appState.phase = .results
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
