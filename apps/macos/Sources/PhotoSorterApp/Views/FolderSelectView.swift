import SwiftUI
import UniformTypeIdentifiers

struct FolderSelectView: View {
    @Environment(AppState.self) private var appState

    @State private var isDropTargeted = false
    @State private var isFolderImporterPresented = false
    @State private var isLoadingManifest = false

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
                    .disabled(isLoadingManifest)

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

                // Loading overlay
                if isLoadingManifest {
                    ProgressView("Loading manifest…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
            .animation(.easeInOut(duration: 0.2), value: isDropTargeted)
            .navigationTitle("Photo Sorter")
        }
        .fileImporter(
            isPresented: $isFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                handleFolder(url)
            case .failure(let error):
                appState.errorMessage = String(
                    format: String(localized: "Could not open folder: %@", bundle: .appResources),
                    locale: .current,
                    error.localizedDescription
                )
            }
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

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
            else { return }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue
            else { return }

            Task { @MainActor in
                handleFolder(url)
            }
        }

        return true
    }

    // MARK: - Handle selected folder

    private func handleFolder(_ url: URL) {
        appState.inputDir = url
        appState.errorMessage = nil

        let manifestURL = PhotoSorterCachePaths.manifestURL(for: url)

        // Load the manifest off the main thread to avoid UI stalls on large files.
        isLoadingManifest = true
        Task {
            let manifest = await loadManifestAsync(from: manifestURL)
            await MainActor.run {
                isLoadingManifest = false
                if let manifest {
                    applyExistingManifest(manifest)
                } else if FileManager.default.fileExists(atPath: manifestURL.path) {
                    appState.errorMessage = String(
                        localized: "Existing manifest.json in PhotoSorter_Cache could not be read and will be overwritten.",
                        bundle: .appResources
                    )
                    appState.phase = .parameters
                } else {
                    appState.phase = .parameters
                }
            }
        }
    }

    private func loadManifestAsync(from url: URL) async -> ManifestResult? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            return try? JSONDecoder().decode(ManifestResult.self, from: data)
        }.value
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

        if let preprocessStr = mp.preprocess,
           let preprocess = PipelineParameters.PreprocessOption(rawValue: preprocessStr) {
            params.preprocess = preprocess
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
