import Foundation

nonisolated enum AdAnalysisBackendAuthentication: Sendable, Equatable {
    #if DEBUG
    case bearer(clientToken: String)
    #endif
    case appAttest(keychainService: String)
}
