import Foundation
import OpenCastAnalysis
import Synchronization

/// The pacers of one app session: one ``AnalysisKeyPacer`` per provider key,
/// shared by every transport that sends with that key, so a rate limit seen
/// by one run paces every later run on the key for the rest of the session.
/// Holds a digest of each key, never the key.
public final class AnalysisKeyPacing: Sendable {
    private struct Identity: Hashable {
        var provider: AnalysisProvider
        var keyDigest: Data
    }

    public let clock: any AnalysisClock
    private let pacers = Mutex<[Identity: AnalysisKeyPacer]>([:])

    public init(clock: any AnalysisClock = AnalysisSystemClock()) {
        self.clock = clock
    }

    /// The key's pacer, created with `maxInFlight` (the ad-detection
    /// window's `max_in_flight`) on first use.
    public func pacer(provider: AnalysisProvider, key: AnalysisProviderKey, maxInFlight: Int) -> AnalysisKeyPacer {
        let identity = Identity(provider: provider, keyDigest: key.digest)
        return pacers.withLock { pacers in
            if let existing = pacers[identity] { return existing }
            let pacer = AnalysisKeyPacer(maxInFlight: maxInFlight, clock: clock)
            pacers[identity] = pacer
            return pacer
        }
    }
}
