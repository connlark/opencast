import Foundation

/// Slugs the app links to from Settings footers. A test asserts each one
/// exists in the bundled document.
nonisolated enum HelpTopicID {
    static let whyWeCharge = "why-we-charge"
    static let credits = "credits"
    static let voiceBoost = "voice-boost"
    static let adDetection = "ad-detection"
    static let transcriptionEngines = "transcription-engines"
    static let iCloudSync = "icloud-sync"
    static let storage = "storage"
    static let notifications = "notifications"
    static let siri = "siri"

    static let all = [
        whyWeCharge,
        credits,
        voiceBoost,
        adDetection,
        transcriptionEngines,
        iCloudSync,
        storage,
        notifications,
        siri,
    ]
}
