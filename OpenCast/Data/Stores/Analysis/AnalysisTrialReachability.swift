import Foundation
import Observation

/// Whether the trial service can be used from this build and device, the
/// fact behind "included until the date". It makes no request to opencast,
/// but resolving can read `AppTransaction`, so a cold launch starts unknown,
/// and unknown is never read as unavailable. Resolved once and kept for the
/// session.
@Observable
final class AnalysisTrialReachability {
    enum State: Sendable, Equatable {
        case unknown
        case available
        case unavailable
    }

    private(set) var state = State.unknown

    @ObservationIgnored private let read: @Sendable () async -> Bool
    @ObservationIgnored private var resolution: Task<State, Never>?

    init(read: @escaping @Sendable () async -> Bool) {
        self.read = read
    }

    /// Whether a free-tier Google key's ad detection can be handed to the
    /// trial service: the service is reachable and the trial has not begun.
    /// Decided with no request to opencast, so a paid key's run never waits
    /// on opencast's service.
    func isHandoverWindowOpen(trialStartsAt: Date, now: Date) -> Bool {
        state == .available && now < trialStartsAt
    }

    /// Starts this session's one resolution; every later caller shares it.
    @discardableResult
    func start() -> Task<State, Never> {
        if let resolution {
            return resolution
        }
        let resolution = Task { [read] in
            let resolved: State = await read() ? .available : .unavailable
            state = resolved
            return resolved
        }
        self.resolution = resolution
        return resolution
    }

    /// The resolved fact, waiting for it when it is still unknown.
    @discardableResult
    func resolve() async -> State {
        await start().value
    }
}
