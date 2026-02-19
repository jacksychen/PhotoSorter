import Foundation

/// Decoded representation of the pipeline's manifest.json output.
public struct ManifestResult: Decodable {
    public let version: Int?
    public let inputDir: String?
    public let total: Int?
    public let parameters: ManifestParameters?
    public let clusters: [Cluster]

    public enum CodingKeys: String, CodingKey {
        case version
        case inputDir = "input_dir"
        case total, parameters, clusters
    }

    public struct ManifestParameters: Decodable {
        public let distanceThreshold: Double?
        public let temporalWeight: Double?
        public let linkage: String?
        public let pooling: String?
        public let batchSize: Int?
        public let device: String?

        public enum CodingKeys: String, CodingKey {
            case distanceThreshold = "distance_threshold"
            case temporalWeight = "temporal_weight"
            case linkage, pooling
            case batchSize = "batch_size"
            case device
        }
    }

    public struct Cluster: Decodable, Identifiable {
        public let clusterId: Int
        public let count: Int
        public let photos: [Photo]

        public var id: Int { clusterId }

        public enum CodingKeys: String, CodingKey {
            case clusterId = "cluster_id"
            case count, photos
        }
    }

    public struct Photo: Decodable, Identifiable {
        public let position: Int?
        public let originalIndex: Int?
        public let filename: String
        public let originalPath: String

        public var id: String { originalPath }

        public init(position: Int?, originalIndex: Int?, filename: String, originalPath: String) {
            self.position = position
            self.originalIndex = originalIndex
            self.filename = filename
            self.originalPath = originalPath
        }

        public enum CodingKeys: String, CodingKey {
            case position
            case originalIndex = "original_index"
            case filename
            case originalPath = "original_path"
        }
    }
}
