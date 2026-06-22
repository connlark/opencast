import Foundation
import UIKit

final class RemoteNotificationRegistrationBridge {
    static let shared = RemoteNotificationRegistrationBridge()

    private var continuation: CheckedContinuation<Data, Error>?
    private var deliveryContinuation: CheckedContinuation<String, Error>?
    private var registrationID: UUID?
    private var deliveryID: UUID?
    private var deliveryTimeoutTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init() {}

    func registerForRemoteNotifications() async throws -> Data {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                replacePendingContinuation(with: continuation, id: requestID)
                timeoutTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(20))
                    guard !Task.isCancelled else {
                        return
                    }
                    finish(
                        id: requestID,
                        .failure(RemoteNotificationRegistrationError.timedOut)
                    )
                }
                UIApplication.shared.registerForRemoteNotifications()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(id: requestID, .failure(CancellationError()))
            }
        }
    }

    func didRegister(deviceToken: Data) {
        finish(.success(deviceToken))
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

    private func replacePendingContinuation(
        with nextContinuation: CheckedContinuation<Data, Error>,
        id: UUID
    ) {
        continuation?.resume(throwing: CancellationError())
        timeoutTask?.cancel()
        continuation = nextContinuation
        registrationID = id
    }

    private func finish(id: UUID, _ result: Result<Data, Error>) {
        guard registrationID == id else {
            return
        }

        finish(result)
    }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        registrationID = nil
        timeoutTask?.cancel()
        timeoutTask = nil

        switch result {
        case .success(let deviceToken):
            continuation.resume(returning: deviceToken)
        case .failure(let error):
            continuation.resume(throwing: error)
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
