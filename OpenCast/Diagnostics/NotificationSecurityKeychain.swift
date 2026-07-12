import Foundation

nonisolated struct NotificationSecurityKeychain: Sendable {
    let appAttestKeychain: AppAttestKeychain

    init(configuration: NotificationBackendConfiguration = .current) {
        self.appAttestKeychain = AppAttestKeychain(service: configuration.keychainService)
    }

    func loadOrCreateInstallID() throws -> String {
        try appAttestKeychain.loadOrCreateInstallID()
    }

    func loadInstallID() throws -> String? {
        try appAttestKeychain.loadInstallID()
    }

    func loadAppAttestKeyID() throws -> String? {
        try appAttestKeychain.loadAppAttestKeyID()
    }

    func saveAppAttestKeyID(_ keyID: String) throws {
        try appAttestKeychain.saveAppAttestKeyID(keyID)
    }

    func deleteAppAttestKeyID() throws {
        try appAttestKeychain.deleteAppAttestKeyID()
    }

    func deleteAll() throws {
        try appAttestKeychain.deleteAll()
    }
}
