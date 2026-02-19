import Foundation

/// Decoded representation of the pipeline's manifest.json output.
struct ManifestResult: Decodable {
    let version: Int?
    let inputDir: String?
    let total: Int?
    let parameters: ManifestParameters?
    let clusters: [Cluster]

    enum CodingKeys: String, CodingKey {
        case version
        case inputDir = "input_dir"
        case total, parameters, clusters
    }

    struct ManifestParameters: Decodable {
        let distanceThreshold: Double?
        let temporalWeight: Double?
        let linkage: String?
        let pooling: String?
        let batchSize: Int?
        let device: String?

        enum CodingKeys: String, CodingKey {
            case distanceThreshold = "distance_threshold"
            case temporalWeight = "temporal_weight"
            case linkage, pooling
            case batchSize = "batch_size"
            case device
        }
    }

    struct Cluster: Decodable, Identifiable {
        let clusterId: Int
        let count: Int
        let photos: [Photo]

        var id: Int { clusterId }

        enum CodingKeys: String, CodingKey {
            case clusterId = "cluster_id"
            case count, photos
        }
    }

    struct Photo: Decodable, Identifiable {
        let position: Int?
        let originalIndex: Int?
        let filename: String
        let originalPath: String

        var id: String { originalPath }

        enum CodingKeys: String, CodingKey {
            case position
            case originalIndex = "original_index"
            case filename
            case originalPath = "original_path"
        }
    }
}
