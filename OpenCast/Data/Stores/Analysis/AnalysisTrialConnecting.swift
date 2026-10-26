import Foundation
import OpenCastAnalysisProviders

/// What route resolution reads from the trial service connection, so a
/// test can stand in for the build's configuration and the device's
/// ability to sign.
nonisolated protocol AnalysisTrialConnecting: Sendable {
    /// Whether this build and device can use a trial route at all, without
    /// any request.
    var isConfigured: Bool { get }

    /// The exchange for this build's deployment, or `nil` when it has no
    /// trial route or this device cannot sign for it.
    func exchange(trialEndpoint: URL) async -> (any AnalysisTrialProxyExchange)?
}
