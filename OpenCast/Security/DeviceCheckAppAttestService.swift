import DeviceCheck
import Foundation

nonisolated struct DeviceCheckAppAttestService: AppAttestServiceProtocol, @unchecked Sendable {
    static let shared = Self(service: DCAppAttestService.shared)

    private let service: DCAppAttestService

    var isSupported: Bool {
        service.isSupported
    }

    func generateKey() async throws -> String {
        try await service.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await service.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}
