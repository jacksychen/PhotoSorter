import SwiftUI

struct ParameterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Form {
            if let error = appState.errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                } header: {
                    Text("Warning")
                }
            }

            // MARK: - Selected folder info
            Section {
                LabeledContent("Folder") {
                    if let inputURL = appState.inputDir {
                        PathControlView(url: inputURL)
                            .frame(maxWidth: 420)
                    } else {
                        Text("No folder selected")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Input")
            }

            // MARK: - Pipeline parameters
            Section {
                Picker("Device", selection: $appState.parameters.device) {
                    ForEach(PipelineParameters.DeviceOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                Stepper(
                    "Batch Size: \(appState.parameters.batchSize)",
                    value: $appState.parameters.batchSize,
                    in: 1...4096
                )

                Picker("Pooling", selection: $appState.parameters.pooling) {
                    ForEach(PipelineParameters.PoolingOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Distance Threshold: \(appState.parameters.distanceThreshold, specifier: "%.2f")")
                    Slider(
                        value: $appState.parameters.distanceThreshold,
                        in: 0.01...2.0
                    )
                }

                Picker("Linkage", selection: $appState.parameters.linkage) {
                    ForEach(PipelineParameters.LinkageOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Temporal Weight: \(appState.parameters.temporalWeight, specifier: "%.2f")")
                    Slider(
                        value: $appState.parameters.temporalWeight,
                        in: 0.0...2.0
                    )
                }
            } header: {
                Text("Parameters")
            }

            // MARK: - Actions
            Section {
                HStack {
                    Button {
                        appState.phase = .folderSelect
                    } label: {
                        Label("Back", systemImage: "arrow.left")
                    }
                    .controlSize(.large)

                    Spacer()

                    Button {
                        appState.resetProgress()
                        appState.phase = .progress
                    } label: {
                        Label("Start Clustering", systemImage: "play.fill")
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
