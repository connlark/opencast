import Foundation

enum AppleSpeechAssetLocaleStatus: String, Sendable, Equatable {
    case unsupported
    case supported
    case downloading
    case installed
}
