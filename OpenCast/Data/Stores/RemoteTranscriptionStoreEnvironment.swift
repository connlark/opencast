import Foundation
import StoreKit

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
