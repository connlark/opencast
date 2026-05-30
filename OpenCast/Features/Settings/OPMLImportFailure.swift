import Foundation

struct OPMLImportFailure: Identifiable, Sendable, Equatable {
    var id: String {
        "\(feedURL)|\(title ?? "")|\(message)"
    }

    var feedURL: String
    var title: String?
    var message: String
}
