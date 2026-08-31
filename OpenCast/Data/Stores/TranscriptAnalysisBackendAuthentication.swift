import Foundation

nonisolated enum TranscriptAnalysisBackendAuthentication: Sendable, Equatable {
    #if DEBUG
    case bearer(clientToken: String)
    #endif
    case appAttest(keychainService: String)
}
