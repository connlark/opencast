import Foundation

nonisolated enum HelpBlock: Equatable, Sendable {
    case heading(String)
    case paragraph(AttributedString)
    case bullets([AttributedString])
    case callout(symbol: String, title: String?, text: AttributedString)
    case link(title: String, url: URL)
    /// Block types newer than this build render nothing rather than failing
    /// the whole document.
    case unsupported(type: String)
}

extension HelpBlock: Decodable {
    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case items
        case symbol
        case title
        case url
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "heading":
            self = .heading(try container.decode(String.self, forKey: .text))
        case "paragraph":
            self = .paragraph(HelpMarkdown.attributedString(try container.decode(String.self, forKey: .text)))
        case "bullets":
            self = .bullets(
                try container.decode([String].self, forKey: .items).map(HelpMarkdown.attributedString)
            )
        case "callout":
            self = .callout(
                symbol: try container.decode(String.self, forKey: .symbol),
                title: try container.decodeIfPresent(String.self, forKey: .title),
                text: HelpMarkdown.attributedString(try container.decode(String.self, forKey: .text))
            )
        case "link":
            self = .link(
                title: try container.decode(String.self, forKey: .title),
                url: try container.decode(URL.self, forKey: .url)
            )
        default:
            self = .unsupported(type: type)
        }
    }
}
