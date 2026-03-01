import SwiftUI

struct PipelineProgressView: View {
    @Environment(AppState.self) private var appState

    @State private var runTask: Task<Void, Never>? = nil
    @State private var manifestLoadTask: Task<Void, Never>? = nil

    private let progressStepRowCornerRadius: CGFloat = 12

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Processing...")
                .font(.title)
                .bold()

            // MARK: - Step list
            VStack(spacing: 8) {
                ForEach(appState.progressSteps.indices, id: \.self) { index in
                    let stepStatus = appState.progressSteps[index]

                    HStack(spacing: 10) {
                        stepIcon(for: stepStatus.state)
                            .frame(width: 20)
                        Text(stepStatus.step.displayName)
                            .foregroundStyle(
                                stepStatus.state == .pending ? .secondary : .primary
                            )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background {
                        if index.isMultiple(of: 2) == false {
                            RoundedRectangle(cornerRadius: progressStepRowCornerRadius, style: .continuous)
                                .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                        }
                    }
                }
            }
            .frame(maxWidth: 360)

            // MARK: - Detail and progress bar
            if !appState.currentDetail.isEmpty {
                Text(appState.currentDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if appState.progressTotal > 0 {
                ProgressView(
                    value: Double(appState.progressProcessed),
                    total: Double(appState.progressTotal)
                )
                .frame(maxWidth: 400)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 400)
            }

            // MARK: - Error display
            if let error = appState.errorMessage {
                VStack(spacing: 12) {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Button {
                        appState.phase = .parameters
                    } label: {
                        Label("Back", systemImage: "arrow.left")
                    }
                    .controlSize(.large)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
        .onAppear {
            startPipeline()
        }
        .onDisappear {
            runTask?.cancel()
            runTask = nil
            manifestLoadTask?.cancel()
            manifestLoadTask = nil
        }
    }

    // MARK: - Step icon

    @ViewBuilder
    private func stepIcon(for state: StepState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.gray)
        case .active:
            Image(systemName: "clock")
                .foregroundStyle(.blue)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }

    // MARK: - Pipeline execution

    private func startPipeline() {
        runTask?.cancel()
        runTask = nil
        manifestLoadTask?.cancel()
        manifestLoadTask = nil

        guard let inputDir = appState.inputDir else {
            appState.errorMessage = String(
                localized: "No folder selected. Please go back and choose a folder.",
                bundle: .appResources
            )
            return
        }

        runTask = Task {
            let runner = PipelineRunner()
            let stream = runner.run(dir: inputDir, params: appState.parameters)
            var receivedComplete = false
            var receivedError = false

            for await message in stream {
                if Task.isCancelled { break }

                if message.type == .complete {
                    receivedComplete = true
                } else if message.type == .error {
                    receivedError = true
                }

                await MainActor.run {
                    handleMessage(message)
                }
            }

            if Task.isCancelled {
                return
            }

            if !receivedComplete && !receivedError {
                await MainActor.run {
                    if appState.phase == .progress, appState.errorMessage == nil {
                        appState.errorMessage = String(
                            localized: "Pipeline ended unexpectedly. Please check logs and try again.",
                            bundle: .appResources
                        )
                    }
                }
            }
        }
    }

    @MainActor
    private func handleMessage(_ message: PipelineMessage) {
        switch message.type {
        case .progress:
            if let stepName = message.step {
                if let currentStep = StepKind(rawValue: stepName) {
                    updateStepStates(current: currentStep)
                } else {
                    NSLog("[PipelineProgressView] Unknown pipeline step: '%@'. The Python pipeline may have been updated.", stepName)
                }
            }

            if let detail = message.detail {
                appState.currentDetail = PipelineProgressMessageLocalizer.localizedDetail(detail)
            }

            if let processed = message.processed {
                appState.progressProcessed = processed
            }

            if let total = message.total {
                appState.progressTotal = total
            }

        case .complete:
            // Mark all steps as done.
            for i in appState.progressSteps.indices {
                appState.progressSteps[i].state = .done
            }

            // Load the manifest off the main thread to avoid blocking UI.
            let manifestPath: String
            if let mp = message.manifestPath {
                manifestPath = mp
            } else if let inputDir = appState.inputDir {
                manifestPath = PhotoSorterCachePaths.manifestURL(for: inputDir).path
            } else {
                appState.errorMessage = String(localized: "No manifest path available.", bundle: .appResources)
                return
            }

            let path = manifestPath
            manifestLoadTask?.cancel()
            manifestLoadTask = Task {
                defer { manifestLoadTask = nil }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: URL(fileURLWithPath: path))
                    }.value
                    guard !Task.isCancelled else { return }
                    let manifest = try JSONDecoder().decode(ManifestResult.self, from: data)
                    guard appState.phase == .progress else { return }
                    appState.manifestResult = manifest
                    appState.selectedSidebarSelection = .allPhotos
                    appState.selectedPhotoIndex = 0
                    appState.phase = .results
                } catch {
                    guard !Task.isCancelled else { return }
                    guard appState.phase == .progress else { return }
                    appState.errorMessage = String(
                        format: String(localized: "Failed to load manifest: %@", bundle: .appResources),
                        locale: .current,
                        error.localizedDescription
                    )
                }
            }

        case .error:
            let fallback = String(localized: "An unknown error occurred.", bundle: .appResources)
            appState.errorMessage = PipelineProgressMessageLocalizer.localizedErrorMessage(
                message.message ?? fallback
            )
        }
    }

    @MainActor
    private func updateStepStates(current: StepKind) {
        let allSteps = StepKind.allCases
        guard let currentIndex = allSteps.firstIndex(of: current) else { return }

        for i in appState.progressSteps.indices {
            let stepKind = appState.progressSteps[i].step
            guard let stepIndex = allSteps.firstIndex(of: stepKind) else { continue }

            if stepIndex < currentIndex {
                appState.progressSteps[i].state = .done
            } else if stepIndex == currentIndex {
                appState.progressSteps[i].state = .active
            } else {
                appState.progressSteps[i].state = .pending
            }
        }
    }

}
