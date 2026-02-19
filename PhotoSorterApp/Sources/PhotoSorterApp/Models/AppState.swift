import SwiftUI

/// The four phases of the application workflow.
enum AppPhase {
    case folderSelect
    case parameters
    case progress
    case results
}

/// Pipeline step identifiers (matches Python STEPS tuple).
enum StepKind: String, CaseIterable {
    case discover, model, embed, similarity, cluster, output

    var displayName: String {
        switch self {
        case .discover:   return "Discovering images"
        case .model:      return "Loading model"
        case .embed:      return "Extracting embeddings"
        case .similarity: return "Computing similarity"
        case .cluster:    return "Clustering"
        case .output:     return "Writing manifest"
        }
    }
}

/// Visual state of a single pipeline step.
enum StepState {
    case pending, active, done
}

/// Status of one pipeline step for the progress view.
struct StepStatus: Identifiable {
    let step: StepKind
    var state: StepState = .pending

    var id: StepKind { step }
}

/// Global observable application state — single source of truth.
@Observable
final class AppState {
    var phase: AppPhase = .folderSelect

    // Phase 1
    var inputDir: URL? = nil

    // Phase 2
    var parameters: PipelineParameters = .defaults

    // Phase 3
    var progressSteps: [StepStatus] = StepKind.allCases.map { StepStatus(step: $0) }
    var currentDetail: String = ""
    var progressProcessed: Int = 0
    var progressTotal: Int = 0
    var errorMessage: String? = nil

    // Phase 4
    var manifestResult: ManifestResult? = nil
    var selectedClusterIndex: Int = 0

    /// Reset progress state before starting a new pipeline run.
    func resetProgress() {
        progressSteps = StepKind.allCases.map { StepStatus(step: $0) }
        currentDetail = ""
        progressProcessed = 0
        progressTotal = 0
        errorMessage = nil
    }
}
