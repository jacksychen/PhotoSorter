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
            case .auto: return "Auto"
            case .mps:  return "Apple GPU"
            case .cpu:  return "CPU"
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
            case .letterbox: return "Letterbox"
            case .timm: return "TIMM (strict)"
            }
        }
    }

    enum LinkageOption: String, CaseIterable, Identifiable {
        case average, complete, single
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }
}
