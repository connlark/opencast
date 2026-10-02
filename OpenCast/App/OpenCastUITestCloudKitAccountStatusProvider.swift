#if DEBUG
struct OpenCastUITestCloudKitAccountStatusProvider: CloudKitAccountStatusProviding {
    let status: SyncAccountStatus
    var delay: Duration = .zero

    func accountStatus() async throws -> SyncAccountStatus {
        if delay > .zero {
            try await Task.sleep(for: delay)
        }
        return status
    }
}
#endif
