import Foundation

enum AppleSpeechAssetState: Equatable {
    case unknown
    case unavailable
    case checking
    case ready(installedLocaleIdentifiers: [String])
    case installing(localeIdentifier: String, fractionCompleted: Double)
    case failed(String)
}
