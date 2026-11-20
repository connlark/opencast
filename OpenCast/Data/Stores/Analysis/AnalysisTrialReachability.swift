import Foundation
import Observation

/// Makes no request to opencast, but resolving can read `AppTransaction`, so a cold launch starts
/// `unknown`, and `unknown` is never read as unavailable. Resolved once per session.
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

    func isHandoverWindowOpen(trialStartsAt: Date, now: Date) -> Bool {
        state == .available && now < trialStartsAt
    }

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

    @discardableResult
    func resolve() async -> State {
        await start().value
    }
}
