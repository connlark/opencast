import Foundation

// NotificationCenter owns the observer token; this helper stores it only for deinit removal.
nonisolated final class MemoryWarningObserver: @unchecked Sendable {
    private let notificationCenter: NotificationCenter
    private var observer: (any NSObjectProtocol)?

    init(
        notificationCenter: NotificationCenter = .default,
        name: Notification.Name?,
        onWarning: @escaping @Sendable () -> Void
    ) {
        self.notificationCenter = notificationCenter
        guard let name else {
            return
        }

        observer = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: nil
        ) { _ in
            onWarning()
        }
    }

    deinit {
        if let observer {
            notificationCenter.removeObserver(observer)
        }
    }
}
