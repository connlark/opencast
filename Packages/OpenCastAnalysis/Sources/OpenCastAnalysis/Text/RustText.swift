enum RustText {
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        RustCharacterTables.whitespaceRanges.contains(scalar.value)
    }

    /// From the services' table, not the OS's Unicode data, which differs on some private-use
    /// scalars and can change with an OS update.
    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        RustCharacterTables.alphanumericRanges.contains(scalar.value)
    }

    static func lowercase(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        RustCharacterTables.lowercaseMap[scalar.value] ?? [scalar]
    }

    /// Compares UTF-8 bytes: Swift's `==` equates canonically equivalent spellings.
    static func same(_ lhs: String?, _ rhs: String) -> Bool {
        lhs.map { $0.utf8.elementsEqual(rhs.utf8) } ?? false
    }

    static func containsBytes(_ haystack: String, _ needle: String) -> Bool {
        let bytes = Array(haystack.utf8)
        return !bytes.byteOccurrences(of: Array(needle.utf8)).isEmpty || needle.isEmpty
    }

    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[first...last])
    }

    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isWhitespace)
    }

    static func charCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    static func whitespaceWordCount(_ text: String) -> Int {
        var count = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                inWord = false
            } else if !inWord {
                inWord = true
                count += 1
            }
        }
        return count
    }

    /// Lowercases each scalar without context, so a capital sigma always becomes σ. The app's
    /// word-boundary resolver must tokenize the same way.
    static func normalizedReceiptTokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isAlphanumeric(scalar) {
                current.append(contentsOf: lowercase(scalar))
            } else if !current.isEmpty {
                tokens.append(String(current))
                current = String.UnicodeScalarView()
            }
        }
        if !current.isEmpty { tokens.append(String(current)) }
        return tokens
    }
}

extension Array where Element == String {
    func occurrences(of needle: [String]) -> [Int] {
        guard !needle.isEmpty, needle.count <= count else { return [] }
        return (0...(count - needle.count)).filter { matchesRun(needle, at: $0) }
    }

    func containsRun(_ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        return (0...(count - needle.count)).contains { matchesRun(needle, at: $0) }
    }

    /// Compares bytes: `==` would match canonically equivalent spellings the services reject.
    private func matchesRun(_ needle: [String], at start: Int) -> Bool {
        for offset in needle.indices where !self[start + offset].utf8.elementsEqual(needle[offset].utf8) {
            return false
        }
        return true
    }
}
