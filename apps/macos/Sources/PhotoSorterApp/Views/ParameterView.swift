import SwiftUI

struct ParameterView: View {
    @Environment(AppState.self) private var appState

    @State private var showAdvanced = false
    @State private var thresholdText = ""
    @State private var temporalText = ""

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(spacing: 0) {
                Spacer()
                    .frame(height: 32)

                // MARK: - Header

                VStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 40, weight: .thin))
                        .foregroundStyle(.secondary)
                        .symbolRenderingMode(.hierarchical)

                    Text("Clustering Parameters")
                        .font(.title2.weight(.semibold))

                    Text("Fine-tune how your photos are grouped")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 28)

                // MARK: - Error banner

                if let error = appState.errorMessage {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(error)
                            .font(.callout)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 40)
                    .padding(.bottom, 16)
                }

                // MARK: - Main parameters

                mainParametersCard
                    .padding(.horizontal, 40)
                    .padding(.bottom, 12)

                // MARK: - Advanced parameters

                advancedParametersCard
                    .padding(.horizontal, 40)
                    .padding(.bottom, 24)

                // MARK: - Actions

                actionButtons
                    .padding(.horizontal, 40)

                Spacer()
                    .frame(height: 32)
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            thresholdText = String(format: "%.2f", appState.parameters.distanceThreshold)
            temporalText = String(format: "%.2f", appState.parameters.temporalWeight)
        }
    }

    // MARK: - Main Parameters Card

    @ViewBuilder
    private var mainParametersCard: some View {
        @Bindable var appState = appState

        VStack(spacing: 14) {
            HStack {
                Label("Basic", systemImage: "tuningfork")
                    .font(.headline)
                Spacer()
            }

            // 1. Distance Threshold
            sliderRow(
                title: "Cluster Granularity",
                caption: "Lower = more groups, higher = fewer"
            ) {
                tickedSlider(
                    value: $appState.parameters.distanceThreshold,
                    in: 0.05...0.4,
                    step: 0.01,
                    tickCount: 8
                )
                .onChange(of: appState.parameters.distanceThreshold) { _, newValue in
                    thresholdText = String(format: "%.2f", newValue)
                }
            } trailing: {
                TextField("", text: $thresholdText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .onSubmit {
                        if let value = Double(thresholdText), value > 0 {
                            appState.parameters.distanceThreshold = value
                        } else {
                            thresholdText = String(
                                format: "%.2f",
                                appState.parameters.distanceThreshold
                            )
                        }
                    }
            }

            Divider()

            // 2. Temporal Weight
            sliderRow(
                title: "Temporal Weight",
                caption: "How much shooting time affects grouping"
            ) {
                tickedSlider(
                    value: $appState.parameters.temporalWeight,
                    in: 0.0...0.4,
                    step: 0.01,
                    tickCount: 9
                )
                .onChange(of: appState.parameters.temporalWeight) { _, newValue in
                    temporalText = String(format: "%.2f", newValue)
                }
            } trailing: {
                TextField("", text: $temporalText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .multilineTextAlignment(.center)
                    .font(.body.monospacedDigit())
                    .onSubmit {
                        if let value = Double(temporalText), value >= 0 {
                            appState.parameters.temporalWeight = value
                        } else {
                            temporalText = String(
                                format: "%.2f",
                                appState.parameters.temporalWeight
                            )
                        }
                    }
            }

            Divider()

            // 3. Pooling
            inlineRow(
                title: "Feature Aggregation",
                caption: "How image features are extracted"
            ) {
                Picker("", selection: $appState.parameters.pooling) {
                    ForEach(PipelineParameters.PoolingOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Divider()

            // 4. Linkage
            inlineRow(
                title: "Cluster Linkage",
                caption: "Strategy for merging similar groups"
            ) {
                Picker("", selection: $appState.parameters.linkage) {
                    ForEach(PipelineParameters.LinkageOption.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Advanced Parameters Card

    @ViewBuilder
    private var advancedParametersCard: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Label("Advanced", systemImage: "gearshape.2")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showAdvanced {
                VStack(spacing: 14) {
                    Divider()
                        .padding(.top, 10)

                    // 1. Device
                    inlineRow(
                        title: "Compute Device",
                        caption: "Hardware for feature extraction"
                    ) {
                        Picker("", selection: $appState.parameters.device) {
                            ForEach(PipelineParameters.DeviceOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Divider()

                    // 2. Preprocessing
                    inlineRow(
                        title: "Image Preprocess",
                        caption: "Letterbox vs TIMM strict for A/B comparison"
                    ) {
                        Picker("", selection: $appState.parameters.preprocess) {
                            ForEach(PipelineParameters.PreprocessOption.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }

                    Divider()

                    // 3. Batch Size
                    sliderRow(
                        title: "Batch Size",
                        caption: "Images per pass — larger uses more memory"
                    ) {
                        tickedSlider(
                            value: Binding(
                                get: { Double(appState.parameters.batchSize) },
                                set: { appState.parameters.batchSize = Int($0) }
                            ),
                            in: 1...100,
                            step: 1,
                            tickCount: 10
                        )
                    } trailing: {
                        Text("\(appState.parameters.batchSize)")
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(20)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Row Layouts

    /// Slider row: label row on top, full-width slider below — ensures all sliders align.
    @ViewBuilder
    private func sliderRow<S: View, T: View>(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        @ViewBuilder slider: () -> S,
        @ViewBuilder trailing: () -> T
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                slider()
                trailing()
            }
        }
    }

    /// Inline row: label on the left, compact control (picker) on the right.
    @ViewBuilder
    private func inlineRow<Control: View>(
        title: LocalizedStringKey,
        caption: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            control()
        }
    }

    // MARK: - Ticked Slider

    @ViewBuilder
    private func tickedSlider(
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        step: Double,
        tickCount: Int
    ) -> some View {
        VStack(spacing: 0) {
            Slider(value: value, in: range, step: step)

            // Tick marks below the slider track
            HStack(spacing: 0) {
                ForEach(0..<tickCount, id: \.self) { index in
                    if index > 0 {
                        Spacer(minLength: 0)
                    }
                    RoundedRectangle(cornerRadius: 0.5)
                        .fill(Color.secondary.opacity(0.35))
                        .frame(width: 1, height: 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionButtons: some View {
        HStack {
            Button {
                appState.phase = .folderSelect
            } label: {
                Label("Back", systemImage: "arrow.left")
                    .frame(minWidth: 80)
            }
            .controlSize(.large)

            Spacer()

            Button {
                appState.resetProgress()
                appState.phase = .progress
            } label: {
                Label("Start Clustering", systemImage: "play.fill")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }
}
