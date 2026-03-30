import Foundation

/// Represents an ISO or disk image file
struct ImageInfo: Identifiable, Codable {
    let id: UUID
    let url: URL
    let filename: String
    let size: Int64
    let sizeString: String
    let checksumMD5: String?
    let checksumSHA256: String?
    let createdDate: Date?

    var displayName: String {
        "\(filename) - \(sizeString)"
    }

    var fileExtension: String {
        url.pathExtension.lowercased()
    }

    var isValidImage: Bool {
        let validExtensions = ["iso", "img", "dmg", "dd"]
        return validExtensions.contains(fileExtension)
    }
}

/// Checksum algorithm types
enum ChecksumAlgorithm: String, CaseIterable, Identifiable {
    case md5 = "MD5"
    case sha1 = "SHA-1"
    case sha256 = "SHA-256"

    var id: String { rawValue }

    var displayName: String {
        rawValue
    }
}

/// Progress information for disk operations
struct OperationProgress: Identifiable {
    let id: UUID
    var status: String
    var percentage: Double
    var bytesProcessed: Int64
    var totalBytes: Int64
    var speed: Double // bytes per second
    var remainingTime: TimeInterval?
    var isIndeterminate: Bool = false

    var speedString: String {
        ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s"
    }

    var remainingTimeString: String {
        guard let remaining = remainingTime else { return "Calculating..." }
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: remaining) ?? "Unknown"
    }
}

/// Operation result
enum OperationResult {
    case success(message: String)
    case failure(error: Error)
    case cancelled

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let msg):
            return msg
        case .failure(let error):
            return error.localizedDescription
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
