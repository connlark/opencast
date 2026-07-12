import DeviceCheck
import Foundation

nonisolated protocol AppAttestServiceProtocol: Sendable {
    var isSupported: Bool { get }

    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}
