import Foundation

/// Pipeline parameters matching Python's config.DEFAULTS.
struct PipelineParameters {
    var device: DeviceOption = .auto
    var batchSize: Int = 16
    var pooling: PoolingOption = .avg
    var preprocess: PreprocessOption = .letterbox
    var distanceThreshold: Double = 0.2
    var linkage: LinkageOption = .complete
    var temporalWeight: Double = 0.0

    static let defaults = PipelineParameters()

    enum DeviceOption: String, CaseIterable, Identifiable {
        case auto, mps, cpu
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto:
                return String(localized: "Auto", bundle: .appResources)
            case .mps:
                return String(localized: "Apple GPU", bundle: .appResources)
            case .cpu:
                return String(localized: "CPU", bundle: .appResources)
            }
        }
    }

    enum PoolingOption: String, CaseIterable, Identifiable {
        case cls, avg, clsAvg = "cls+avg"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .cls:    return "CLS"
            case .avg:    return "AVG"
            case .clsAvg: return "CLS+AVG"
            }
        }
    }

    enum PreprocessOption: String, CaseIterable, Identifiable {
        case letterbox
        case timm

        var id: String { rawValue }
        var label: String {
            switch self {
            case .letterbox:
                return String(localized: "Letterbox", bundle: .appResources)
            case .timm:
                return String(localized: "TIMM (strict)", bundle: .appResources)
            }
        }
    }

    enum LinkageOption: String, CaseIterable, Identifiable {
        case average, complete, single
        var id: String { rawValue }
        var label: String {
            switch self {
            case .average:
                return String(localized: "Average", bundle: .appResources)
            case .complete:
                return String(localized: "Complete", bundle: .appResources)
            case .single:
                return String(localized: "Single", bundle: .appResources)
            }
        }
    }
}
