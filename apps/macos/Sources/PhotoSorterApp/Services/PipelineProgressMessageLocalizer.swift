import Foundation

package enum PipelineProgressMessageLocalizer {
    package static func localizedDetail(_ detail: String) -> String {
        switch detail {
        case "Discovering images…":
            return String(localized: "Discovering images…", bundle: .appResources)
        case "Loading DINOv3 model…":
            return String(localized: "Loading DINOv3 model…", bundle: .appResources)
        case "Model loaded":
            return String(localized: "Model loaded", bundle: .appResources)
        case "Extracting embeddings…":
            return String(localized: "Extracting embeddings…", bundle: .appResources)
        case "Embeddings extracted":
            return String(localized: "Embeddings extracted", bundle: .appResources)
        case "Computing similarity matrix…":
            return String(localized: "Computing similarity matrix…", bundle: .appResources)
        case "Distance matrix ready":
            return String(localized: "Distance matrix ready", bundle: .appResources)
        case "Clustering…":
            return String(localized: "Clustering…", bundle: .appResources)
        case "Writing manifest…":
            return String(localized: "Writing manifest…", bundle: .appResources)
        case "Manifest written":
            return String(localized: "Manifest written", bundle: .appResources)
        default:
            break
        }

        if let count = extractInt(detail, prefix: "Found ", suffix: " images") {
            return String(
                format: String(localized: "Found %d images", bundle: .appResources),
                locale: .current,
                count
            )
        }

        if let count = extractInt(detail, prefix: "", suffix: " clusters found") {
            return String(
                format: String(localized: "%d clusters found", bundle: .appResources),
                locale: .current,
                count
            )
        }

        return detail
    }

    package static func localizedErrorMessage(_ message: String) -> String {
        if let path = extractSuffix(message, prefix: "Input directory does not exist: ") {
            return String(
                format: String(localized: "Input directory does not exist: %@", bundle: .appResources),
                locale: .current,
                path
            )
        }

        if let path = extractSuffix(message, prefix: "No images found in ") {
            return String(
                format: String(localized: "No images found in %@", bundle: .appResources),
                locale: .current,
                path
            )
        }

        if message == "No images could be loaded successfully" {
            return String(localized: "No images could be loaded successfully", bundle: .appResources)
        }

        return message
    }

    private static func extractInt(_ text: String, prefix: String, suffix: String) -> Int? {
        guard let payload = extractMiddle(text, prefix: prefix, suffix: suffix) else { return nil }
        return Int(payload)
    }

    private static func extractSuffix(_ text: String, prefix: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    private static func extractMiddle(_ text: String, prefix: String, suffix: String) -> String? {
        guard text.hasPrefix(prefix), text.hasSuffix(suffix) else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        let end = text.index(text.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(text[start..<end])
    }
}
