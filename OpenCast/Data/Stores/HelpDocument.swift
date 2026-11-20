import Foundation

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

    /// `.iso8601` rejects fractional seconds, so documents carry second-precision dates.
    static func decode(_ data: Data) throws -> HelpDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HelpDocument.self, from: data)
    }
}
