import Foundation
import Network

nonisolated enum NetworkPathObserver {
    private static let queue = DispatchQueue(label: "com.connor.opencast.network-path", qos: .utility)

    /// Each call owns a fresh monitor, because a cancelled `NWPathMonitor`
    /// cannot be restarted; ending the iteration cancels it.
    static func pathSatisfactionUpdates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in
                monitor.cancel()
            }
            monitor.start(queue: Self.queue)
        }
    }
}
