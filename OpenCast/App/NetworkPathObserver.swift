import Foundation
import Network

nonisolated enum NetworkPathObserver {
    private static let queue = DispatchQueue(label: "com.connor.opencast.network-path", qos: .utility)

    /// Each call owns a fresh monitor, because a cancelled `NWPathMonitor`
    /// cannot be restarted; ending the iteration cancels it.
    static func pathUpdates() -> AsyncStream<NetworkPathSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(NetworkPathSnapshot(path))
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: Self.queue)
        }
    }

    /// The current path: a started monitor reports it at once. Cancellation
    /// ends the wait with `.unavailable`.
    static func currentPath() async -> NetworkPathSnapshot {
        for await path in pathUpdates() {
            return path
        }
        return .unavailable
    }
}
