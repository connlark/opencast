import Foundation

public struct OPMLExporter: Sendable {
    public static let documentTitle = "opencast Subscriptions"
    public static let defaultFilename = "\(documentTitle).opml"

    private static let timestampFormatter = OPMLTimestampFormatter()

    public init() {}

    public func export(
        feedReferences: [OPMLFeedReference],
        generatedAt: Date = .now
    ) throws -> Data {
        guard !feedReferences.isEmpty else {
            throw OPMLError.emptySubscriptionList
        }

        let timestamp = Self.xmlEscaped(Self.timestampFormatter.string(from: generatedAt))
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(Self.xmlEscaped(Self.documentTitle))</title>",
            "    <dateCreated>\(timestamp)</dateCreated>",
            "    <dateModified>\(timestamp)</dateModified>",
            "  </head>",
            "  <body>"
        ]

        for reference in feedReferences {
            lines.append(outlineElement(for: reference))
        }

        lines.append(contentsOf: [
            "  </body>",
            "</opml>",
            ""
        ])

        guard let data = lines.joined(separator: "\n").data(using: .utf8) else {
            throw OPMLError.exportFailed
        }

        return data
    }

    private func outlineElement(for reference: OPMLFeedReference) -> String {
        let title = reference.title ?? reference.feedURL.host ?? reference.canonicalFeedURL
        let escapedTitle = Self.xmlEscaped(title)
        let escapedFeedURL = Self.xmlEscaped(reference.canonicalFeedURL)
        let htmlAttribute = reference.htmlURL.map { #" htmlUrl="\#(Self.xmlEscaped($0.absoluteString))""# } ?? ""

        return #"    <outline type="rss" text="\#(escapedTitle)" title="\#(escapedTitle)" xmlUrl="\#(escapedFeedURL)"\#(htmlAttribute) />"#
    }

    private static func xmlEscaped(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)

        for character in value {
            switch character {
            case "&":
                escaped.append("&amp;")
            case "<":
                escaped.append("&lt;")
            case ">":
                escaped.append("&gt;")
            case "\"":
                escaped.append("&quot;")
            case "'":
                escaped.append("&apos;")
            default:
                escaped.append(character)
            }
        }

        return escaped
    }
}
