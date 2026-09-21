import Foundation
import UIKit

final class RemoteNotificationRegistrationBridge {
    static let shared = RemoteNotificationRegistrationBridge()

    private var continuations: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var deliveryContinuation: CheckedContinuation<String, Error>?
    private var deliveryID: UUID?
    private var deliveryTimeoutTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private let requestRegistration: () -> Void

    init(requestRegistration: @escaping () -> Void = {
        UIApplication.shared.registerForRemoteNotifications()
    }) {
        self.requestRegistration = requestRegistration
    }

    func registerForRemoteNotifications() async throws -> Data {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let needsRequest = continuations.isEmpty
                continuations[requestID] = continuation
                guard needsRequest else { return }
                timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else {
                        return
                    }
                    finish(.failure(RemoteNotificationRegistrationError.timedOut))
                }
                requestRegistration()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID)
            }
        }
    }

    @discardableResult
    func didRegister(deviceToken: Data) -> Bool {
        let wasRequested = !continuations.isEmpty
        finish(.success(deviceToken))
        return wasRequested
    }

    func didFailToRegister(error: Error) {
        finish(.failure(error))
    }

    func waitForDiagnosticNotification() async throws -> String {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                replacePendingDeliveryContinuation(with: continuation, id: requestID)
                deliveryTimeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else {
                        return
                    }
                    finishDelivery(
                        id: requestID,
                        .failure(RemoteNotificationRegistrationError.deliveryTimedOut)
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishDelivery(id: requestID, .failure(CancellationError()))
            }
        }
    }

    func didReceiveDiagnosticNotification() {
        finishDelivery(.success("Received"))
    }

    private func cancel(_ id: UUID) {
        continuations.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if continuations.isEmpty {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let pending = continuations.values
        continuations = [:]
        timeoutTask?.cancel()
        timeoutTask = nil

        for continuation in pending {
            continuation.resume(with: result)
        }
    }

    private func replacePendingDeliveryContinuation(
        with nextContinuation: CheckedContinuation<String, Error>,
        id: UUID
    ) {
        deliveryContinuation?.resume(throwing: CancellationError())
        deliveryTimeoutTask?.cancel()
        deliveryContinuation = nextContinuation
        deliveryID = id
    }

    private func finishDelivery(id: UUID, _ result: Result<String, Error>) {
        guard deliveryID == id else {
            return
        }

        finishDelivery(result)
    }

    private func finishDelivery(_ result: Result<String, Error>) {
        guard let deliveryContinuation else {
            return
        }

        self.deliveryContinuation = nil
        deliveryID = nil
        deliveryTimeoutTask?.cancel()
        deliveryTimeoutTask = nil

        switch result {
        case .success(let status):
            deliveryContinuation.resume(returning: status)
        case .failure(let error):
            deliveryContinuation.resume(throwing: error)
        }
    }
}
