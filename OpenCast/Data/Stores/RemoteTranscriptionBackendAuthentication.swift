import Foundation

nonisolated enum RemoteTranscriptionBackendAuthentication: Sendable, Equatable {
    #if DEBUG
    case bearer(clientToken: String)
    #endif
    case appAttest(keychainService: String)
}
