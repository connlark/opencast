import Foundation

nonisolated struct HelpTopic: Identifiable, Equatable, Sendable, Decodable {
    let id: String
    let title: String
    let symbol: String
    let summary: String
    let updatedAt: Date
    /// Hides the topic on older builds; never fails the document.
    let minAppBuild: Int?
    let related: [String]
    let identifiedBlocks: [HelpTopicBlock]

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case symbol
        case summary
        case updatedAt
        case minAppBuild
        case related
        case blocks
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        symbol = try container.decode(String.self, forKey: .symbol)
        summary = try container.decode(String.self, forKey: .summary)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        minAppBuild = try container.decodeIfPresent(Int.self, forKey: .minAppBuild)
        related = try container.decodeIfPresent([String].self, forKey: .related) ?? []
        identifiedBlocks = HelpTopicBlock.identify(try container.decode([HelpBlock].self, forKey: .blocks))
    }
}
