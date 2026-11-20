import Foundation

/// `id` is persisted and names the bundled `<id>.m4a`.
struct SkipSound: Hashable, Identifiable, Sendable {
    let id: String
    let name: String
}
