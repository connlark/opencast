import Foundation

enum NotificationSecurityRequestBinding {
    nonisolated static func clientDataHash(method: String, path: String, payload: String) -> Data {
        AppAttestRequestBinding.clientDataHash(method: method, path: path, payload: payload)
    }

    nonisolated static func sha256Hex(_ data: Data) -> String {
        AppAttestRequestBinding.sha256Hex(data)
    }
}
