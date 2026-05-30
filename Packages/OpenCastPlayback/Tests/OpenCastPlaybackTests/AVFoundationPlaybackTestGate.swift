import Foundation

@MainActor
enum AVFoundationPlaybackTestGate {
    private static var isLocked = false

    static func acquire() async throws {
        while isLocked {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
        isLocked = true
    }

    static func release() {
        isLocked = false
    }
}
