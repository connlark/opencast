import Foundation
import OpenCastAnalysisProviders

nonisolated protocol AnalysisTrialConnecting: Sendable {
    /// Must not make a request.
    var isConfigured: Bool { get }

    func exchange(trialEndpoint: URL) async -> (any AnalysisTrialProxyExchange)?
}
