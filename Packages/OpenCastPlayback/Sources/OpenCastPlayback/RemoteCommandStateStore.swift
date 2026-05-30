import Foundation
import Synchronization

nonisolated final class RemoteCommandStateStore: Sendable {
    private let state = Mutex(RemoteCommandState.empty)

    func update(_ newState: RemoteCommandState) {
        state.withLock {
            $0 = newState
        }
    }

    func read() -> RemoteCommandState {
        state.withLock { $0 }
    }
}
