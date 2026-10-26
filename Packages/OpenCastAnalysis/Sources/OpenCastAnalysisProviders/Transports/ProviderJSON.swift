import OpenCastAnalysis

/// Lenient reads of provider JSON for classification and usage; the
/// pipeline's strict parsers decide everything that matters for a result.
enum ProviderJSON {
    /// The deepest nesting read from a provider, in a body or in an answer
    /// the pipeline parses out of one. Bodies nest a handful of levels; past
    /// this, one is refused before any parser reads it (``BoundedJSON``).
    static let maximumDepth = 128

    static func parse(_ text: String) -> JSONValue? {
        guard case .value(let value) = BoundedJSON.parse(text, maximumDepth: maximumDepth) else { return nil }
        return value
    }

    /// Whether a body is refused before any parser reads it: nested past
    /// ``maximumDepth``, or with a string left open (not JSON, and nothing
    /// after the open quote was counted). A refused 2xx body is a malformed
    /// answer; a refused error body is classified by its status alone.
    static func refusesBody(_ text: String) -> Bool {
        BoundedJSON.scan(text, maximumDepth: maximumDepth) != .within
    }

    /// Whether an answer the pipeline will parse nests past
    /// ``maximumDepth``: any one text, or the texts joined (the Chapters
    /// pipeline joins a candidate's parts). A string left open in an answer
    /// stops the parser where it opens, so only depth refuses one.
    static func answerTooDeep(_ texts: [String]) -> Bool {
        texts.contains { BoundedJSON.scan($0, maximumDepth: maximumDepth) == .tooDeep }
            || (texts.count > 1 && BoundedJSON.scan(texts.joined(), maximumDepth: maximumDepth) == .tooDeep)
    }

    /// A non-negative integer, or `nil`.
    static func count(_ value: JSONValue?) -> UInt64? {
        guard case .number(let number) = value else { return nil }
        switch number {
        case .unsigned(let value): return value
        case .negative: return nil
        case .double(let value):
            guard value >= 0, value.rounded() == value, value < 1.8e19 else { return nil }
            return UInt64(value)
        }
    }

    /// `true` for an absent member or JSON `null`.
    static func isAbsent(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: true
        default: false
        }
    }

    static func lowercasedASCII(_ text: String) -> String {
        String(decoding: text.utf8.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }, as: UTF8.self)
    }

    static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
