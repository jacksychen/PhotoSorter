import Foundation

/// Decoded representation of the pipeline's manifest.json output.
public struct ManifestResult: Codable, Sendable, Equatable {
    public var version: Int?
    public var inputDir: String?
    public var total: Int?
    public var parameters: ManifestParameters?
    public var clusters: [Cluster]

    public init(
        version: Int? = nil,
        inputDir: String? = nil,
        total: Int? = nil,
        parameters: ManifestParameters? = nil,
        clusters: [Cluster]
    ) {
        self.version = version
        self.inputDir = inputDir
        self.total = total
        self.parameters = parameters
        self.clusters = clusters
    }

    public enum CodingKeys: String, CodingKey {
        case version
        case inputDir = "input_dir"
        case total, parameters, clusters
    }

    public struct ManifestParameters: Codable, Sendable, Equatable {
        public var distanceThreshold: Double?
        public var temporalWeight: Double?
        public var linkage: String?
        public var pooling: String?
        public var preprocess: String?
        public var batchSize: Int?
        public var device: String?

        public init(
            distanceThreshold: Double? = nil,
            temporalWeight: Double? = nil,
            linkage: String? = nil,
            pooling: String? = nil,
            preprocess: String? = nil,
            batchSize: Int? = nil,
            device: String? = nil
        ) {
            self.distanceThreshold = distanceThreshold
            self.temporalWeight = temporalWeight
            self.linkage = linkage
            self.pooling = pooling
            self.preprocess = preprocess
            self.batchSize = batchSize
            self.device = device
        }

        public enum CodingKeys: String, CodingKey {
            case distanceThreshold = "distance_threshold"
            case temporalWeight = "temporal_weight"
            case linkage, pooling, preprocess
            case batchSize = "batch_size"
            case device
        }
    }

    public struct Cluster: Codable, Identifiable, Sendable, Equatable {
        public var clusterId: Int
        public var count: Int
        public var photos: [Photo]

        public var id: Int { clusterId }

        public init(clusterId: Int, count: Int, photos: [Photo]) {
            self.clusterId = clusterId
            self.count = count
            self.photos = photos
        }

        public enum CodingKeys: String, CodingKey {
            case clusterId = "cluster_id"
            case count, photos
        }
    }

    public struct Photo: Codable, Identifiable, Sendable, Equatable {
        public static let checkedPrefix = "CHECK_"

        public var position: Int?
        public var originalIndex: Int?
        public var filename: String
        public var originalPath: String

        public var id: String { originalPath }
        public var isChecked: Bool { filename.hasPrefix(Self.checkedPrefix) }

        public init(position: Int?, originalIndex: Int?, filename: String, originalPath: String) {
            self.position = position
            self.originalIndex = originalIndex
            self.filename = filename
            self.originalPath = originalPath
        }

        public func toggledFilename() -> String {
            if isChecked {
                return String(filename.dropFirst(Self.checkedPrefix.count))
            }
            return Self.checkedPrefix + filename
        }

        public enum CodingKeys: String, CodingKey {
            case position
            case originalIndex = "original_index"
            case filename
            case originalPath = "original_path"
        }
    }
}
