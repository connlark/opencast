import OpenCastAnalysis

/// Lenient reads for classification and usage only; the pipeline's strict parsers decide results.
enum ProviderJSON {
    static let maximumDepth = 128

    static func parse(_ text: String) -> JSONValue? {
        guard case .value(let value) = BoundedJSON.parse(text, maximumDepth: maximumDepth) else { return nil }
        return value
    }

    /// A string left open refuses the body too: nothing after its quote was counted.
    static func refusesBody(_ text: String) -> Bool {
        BoundedJSON.scan(text, maximumDepth: maximumDepth) != .within
    }

    /// The texts are checked joined too, as the Chapters pipeline joins a candidate's parts. An
    /// open string stops the parser where it opens, so only depth refuses an answer.
    static func answerTooDeep(_ texts: [String]) -> Bool {
        texts.contains { BoundedJSON.scan($0, maximumDepth: maximumDepth) == .tooDeep }
            || (texts.count > 1 && BoundedJSON.scan(texts.joined(), maximumDepth: maximumDepth) == .tooDeep)
    }

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
