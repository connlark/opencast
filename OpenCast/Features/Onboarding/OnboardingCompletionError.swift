import Foundation

struct OnboardingCompletionError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? {
        message
    }
}
