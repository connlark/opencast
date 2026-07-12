#if DEBUG
struct OpenCastUITestCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    let status: SyncAccountStatus

    func accountStatus() async throws -> SyncAccountStatus {
        status
    }
}
#endif
