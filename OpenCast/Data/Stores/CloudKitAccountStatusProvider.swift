import CloudKit

struct CloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    let containerIdentifier: String

    init(containerIdentifier: String = OpenCastModelContainerFactory.cloudKitContainerIdentifier) {
        self.containerIdentifier = containerIdentifier
    }

    func accountStatus() async throws -> SyncAccountStatus {
        let status = try await CKContainer(identifier: containerIdentifier).accountStatus()
        return SyncAccountStatus(cloudKitAccountStatus: status)
    }
}

private extension SyncAccountStatus {
    init(cloudKitAccountStatus: CKAccountStatus) {
        switch cloudKitAccountStatus {
        case .available:
            self = .available
        case .noAccount:
            self = .noAccount
        case .restricted:
            self = .restricted
        case .couldNotDetermine:
            self = .couldNotDetermine
        case .temporarilyUnavailable:
            self = .temporarilyUnavailable("CloudKit account status is temporarily unavailable.")
        @unknown default:
            self = .couldNotDetermine
        }
    }
}
