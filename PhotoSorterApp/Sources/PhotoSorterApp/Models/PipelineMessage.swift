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
    let exists: Bool?
    let path: String?

    enum MessageType: String, Decodable {
        case progress
        case complete
        case error
        case manifest  // response to check-manifest
    }

    enum CodingKeys: String, CodingKey {
        case type, step, detail, processed, total
        case manifestPath = "manifest_path"
        case message, exists, path
    }
}
