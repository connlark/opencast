import Foundation

/// A sound the player can play over an automatic ad skip. `id` is what
/// `PlaybackSettingsStore` stores and names the bundled `<id>.m4a`.
struct SkipSound: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}
