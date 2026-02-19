import Foundation

/// A single JSON message from the Python pipeline process (one per line on stdout).
struct PipelineMessage: Decodable {
    let type: MessageType
    let step: String?
    let detail: String?
    let processed: Int?
    let total: Int?
    let manifestPath: String?
    let message: String?

    enum MessageType: String, Decodable {
        case progress
        case complete
        case error
    }

    enum CodingKeys: String, CodingKey {
        case type, step, detail, processed, total
        case manifestPath = "manifest_path"
        case message
    }

    init(
        type: MessageType,
        step: String? = nil,
        detail: String? = nil,
        processed: Int? = nil,
        total: Int? = nil,
        manifestPath: String? = nil,
        message: String? = nil,
    ) {
        self.type = type
        self.step = step
        self.detail = detail
        self.processed = processed
        self.total = total
        self.manifestPath = manifestPath
        self.message = message
    }
}
