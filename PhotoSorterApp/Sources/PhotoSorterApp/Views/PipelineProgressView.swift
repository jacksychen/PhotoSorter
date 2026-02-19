import SwiftUI

struct PipelineProgressView: View {
    @Environment(AppState.self) private var appState

    @State private var runTask: Task<Void, Never>? = nil

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("Processing...")
                .font(.title)
                .bold()

            // MARK: - Step list
            VStack(alignment: .leading, spacing: 12) {
                ForEach(appState.progressSteps) { stepStatus in
                    HStack(spacing: 10) {
                        stepIcon(for: stepStatus.state)
                            .frame(width: 20)
                        Text(stepStatus.step.displayName)
                            .foregroundStyle(
                                stepStatus.state == .pending ? .secondary : .primary
                            )
                    }
                }
            }
            .frame(maxWidth: 300, alignment: .leading)

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
        guard let inputDir = appState.inputDir else {
            appState.errorMessage = "No folder selected. Please go back and choose a folder."
            return
        }

        runTask = Task {
            let runner = PipelineRunner()
            let stream = runner.run(dir: inputDir, params: appState.parameters)

            for await message in stream {
                if Task.isCancelled { break }

                await MainActor.run {
                    handleMessage(message)
                }
            }
        }
    }

    private func handleMessage(_ message: PipelineMessage) {
        switch message.type {
        case .progress:
            if let stepName = message.step,
               let currentStep = StepKind(rawValue: stepName) {
                updateStepStates(current: currentStep)
            }

            if let detail = message.detail {
                appState.currentDetail = detail
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
                manifestPath = inputDir.appendingPathComponent("manifest.json").path
            } else {
                appState.errorMessage = "No manifest path available."
                return
            }

            let path = manifestPath
            Task.detached {
                do {
                    let data = try Data(contentsOf: URL(fileURLWithPath: path))
                    let manifest = try JSONDecoder().decode(ManifestResult.self, from: data)
                    await MainActor.run {
                        appState.manifestResult = manifest
                        appState.selectedClusterIndex = 0
                        appState.phase = .results
                    }
                } catch {
                    await MainActor.run {
                        appState.errorMessage = "Failed to load manifest: \(error.localizedDescription)"
                    }
                }
            }

        case .error:
            appState.errorMessage = message.message ?? "An unknown error occurred."

        case .manifest:
            break
        }
    }

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
