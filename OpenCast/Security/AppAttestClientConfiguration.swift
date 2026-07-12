import Foundation

nonisolated struct AppAttestClientConfiguration: Sendable {
    let baseURL: URL
    let keychainService: String
    let challengePath: String
    let registerPath: String

    init(
        baseURL: URL,
        keychainService: String,
        challengePath: String = "/v1/app-attest/challenge",
        registerPath: String = "/v1/app-attest/register"
    ) {
        self.baseURL = baseURL
        self.keychainService = keychainService
        self.challengePath = challengePath
        self.registerPath = registerPath
    }
}
