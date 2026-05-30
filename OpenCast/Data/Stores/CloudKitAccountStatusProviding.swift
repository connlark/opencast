protocol CloudKitAccountStatusProviding: Sendable {
    func accountStatus() async throws -> SyncAccountStatus
}
