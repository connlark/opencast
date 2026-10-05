import UserNotifications
@testable import OpenCast

@MainActor
final class FakeAdFreePassNotificationCenter: AdFreePassNotificationCenter {
    var authorizationStatusValue: UNAuthorizationStatus = .authorized
    private(set) var authorizationStatusReadCount = 0
    private(set) var provisionalRequestCount = 0
    private(set) var addedRequests: [UNNotificationRequest] = []
    /// When set, `add` throws it and records nothing.
    var addError: (any Error)?

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationStatusReadCount += 1
        return authorizationStatusValue
    }

    func requestProvisionalAuthorization() async {
        provisionalRequestCount += 1
        if authorizationStatusValue == .notDetermined {
            authorizationStatusValue = .provisional
        }
    }

    func add(_ request: UNNotificationRequest) async throws {
        if let addError {
            throw addError
        }
        addedRequests.append(request)
    }
}
