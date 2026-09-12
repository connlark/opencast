import Foundation

/// Versioned help content: bundled as a fallback, mirrored from the website,
/// and refreshed remotely. Documents with a different schema are ignored.
nonisolated struct HelpDocument: Decodable, Equatable, Sendable {
    static let supportedSchemaVersion = 1
    static let empty = HelpDocument(
        schemaVersion: supportedSchemaVersion,
        updatedAt: .distantPast,
        topics: []
    )

    let schemaVersion: Int
    let updatedAt: Date
    let topics: [HelpTopic]

    init(schemaVersion: Int, updatedAt: Date, topics: [HelpTopic]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.topics = topics
    }

    /// Dates are second-precision ISO 8601; Foundation's `.iso8601` strategy
    /// rejects fractional seconds, which the website validator also forbids.
    static func decode(_ data: Data) throws -> HelpDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HelpDocument.self, from: data)
    }
}
