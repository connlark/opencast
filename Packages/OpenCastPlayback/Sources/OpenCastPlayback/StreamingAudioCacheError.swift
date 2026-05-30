import Foundation

public nonisolated enum StreamingAudioCacheError: LocalizedError, Sendable, Equatable {
    case disabled
    case unsupportedURL
    case hlsUnsupported
    case invalidRange
    case missingValidator
    case validatorChanged
    case noRangeSupport
    case redirected
    case unexpectedStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .disabled:
            "Streaming cache is disabled."
        case .unsupportedURL:
            "This audio URL is not eligible for streaming cache."
        case .hlsUnsupported:
            "HLS streams are not eligible for byte-range cache."
        case .invalidRange:
            "The streaming cache received an invalid byte range."
        case .missingValidator:
            "The server did not provide a stable cache validator."
        case .validatorChanged:
            "The server changed the streaming cache validator."
        case .noRangeSupport:
            "The server does not support byte-range audio requests."
        case .redirected:
            "The streaming cache request redirected."
        case .unexpectedStatus(let status):
            "Unexpected streaming cache HTTP status \(status)."
        }
    }
}
