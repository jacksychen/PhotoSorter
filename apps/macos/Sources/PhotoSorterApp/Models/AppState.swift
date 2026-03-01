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
        case .discover:
            return String(localized: "Discovering images", bundle: .appResources)
        case .model:
            return String(localized: "Loading model", bundle: .appResources)
        case .embed:
            return String(localized: "Extracting embeddings", bundle: .appResources)
        case .similarity:
            return String(localized: "Computing similarity", bundle: .appResources)
        case .cluster:
            return String(localized: "Clustering", bundle: .appResources)
        case .output:
            return String(localized: "Writing manifest", bundle: .appResources)
        }
    }
}

/// Visual state of a single pipeline step.
enum StepState {
    case pending, active, done
}

/// Sidebar selection for filtering photos in results view.
enum SidebarSelection: Hashable {
    case allPhotos
    case checkedPhotos
    case cluster(Int)
}

/// Status of one pipeline step for the progress view.
struct StepStatus: Identifiable {
    let step: StepKind
    var state: StepState = .pending

    var id: StepKind { step }
}

/// Global observable application state — single source of truth.
@Observable
public final class AppState {
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
    var selectedSidebarSelection: SidebarSelection = .allPhotos
    var selectedPhotoIndex: Int = 0

    public init() {}

    /// Reset progress state before starting a new pipeline run.
    func resetProgress() {
        progressSteps = StepKind.allCases.map { StepStatus(step: $0) }
        currentDetail = ""
        progressProcessed = 0
        progressTotal = 0
        errorMessage = nil
    }
}
