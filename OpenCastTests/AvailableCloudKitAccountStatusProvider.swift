@testable import OpenCast

struct AvailableCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    func accountStatus() async throws -> SyncAccountStatus {
        .available
    }
}
