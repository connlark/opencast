import Foundation
import StoreKit

/// StoreKit environment of this install, used to route a Release process to
/// one isolated money/state lane: sandbox/Xcode → prod-staging, production →
/// production, and unknown → disabled.
nonisolated enum RemoteTranscriptionStoreEnvironment: Sendable, Equatable {
    case sandbox
    case xcode
    case production
    case unknown(String)

    init(_ environment: AppStore.Environment) {
        switch environment {
        case .sandbox: self = .sandbox
        case .xcode: self = .xcode
        case .production: self = .production
        default: self = .unknown(environment.rawValue)
        }
    }
}
