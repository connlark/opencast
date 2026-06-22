import Foundation

final class RemoteEpisodeNotificationRouteBridge {
    static let shared = RemoteEpisodeNotificationRouteBridge()

    private var continuation: AsyncStream<RemoteEpisodeNotificationRoute>.Continuation?
    private var streamID: UUID?
    private var pendingRoute: RemoteEpisodeNotificationRoute?

    init() {}

    func routes() -> AsyncStream<RemoteEpisodeNotificationRoute> {
        let streamID = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            replaceContinuation(continuation, id: streamID)
            if let pendingRoute {
                #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
                RemoteEpisodeNotificationRouteDiagnostics.shared.record("Pending Delivered", route: pendingRoute)
                #endif
                continuation.yield(pendingRoute)
                self.pendingRoute = nil
            }
            continuation.onTermination = { @Sendable _ in
                Task { @MainActor [weak self] in
                    self?.clearContinuation(id: streamID)
                }
            }
        }
    }

    func didReceive(route: RemoteEpisodeNotificationRoute) {
        #if DEBUG || INTERNAL_NOTIFICATIONS_DIAGNOSTICS
        RemoteEpisodeNotificationRouteDiagnostics.shared.record("Bridge Received", route: route)
        #endif
        if let continuation {
            continuation.yield(route)
        } else {
            pendingRoute = route
        }
    }

    private func replaceContinuation(
        _ nextContinuation: AsyncStream<RemoteEpisodeNotificationRoute>.Continuation,
        id: UUID
    ) {
        // Notification taps are latest-only; a new root subscriber replaces any older stream.
        continuation?.finish()
        continuation = nextContinuation
        streamID = id
    }

    private func clearContinuation(id: UUID) {
        guard streamID == id else {
            return
        }

        continuation = nil
        streamID = nil
    }
}
