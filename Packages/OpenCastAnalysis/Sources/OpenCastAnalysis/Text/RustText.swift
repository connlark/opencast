/// String predicates and transforms with Rust `std` semantics, so the
/// validators count, trim and split exactly as the services do.
enum RustText {
    /// `char::is_whitespace`, from the services' own table.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        RustCharacterTables.whitespaceRanges.contains(scalar.value)
    }

    /// `char::is_alphanumeric` as the services' toolchain defines it
    /// (Alphabetic, or a number category; never private-use), from their own
    /// table rather than the OS's Unicode data, which differs on some
    /// private-use scalars and can change with an OS update.
    static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        RustCharacterTables.alphanumericRanges.contains(scalar.value)
    }

    /// `char::to_lowercase`, from the services' own table.
    static func lowercase(_ scalar: Unicode.Scalar) -> [Unicode.Scalar] {
        RustCharacterTables.lowercaseMap[scalar.value] ?? [scalar]
    }

    /// Rust string equality: the same UTF-8 bytes. Swift's `==` also equates
    /// canonically equivalent spellings (a Kelvin sign and `K`).
    static func same(_ lhs: String?, _ rhs: String) -> Bool {
        lhs.map { $0.utf8.elementsEqual(rhs.utf8) } ?? false
    }

    /// Rust `str::contains` for a string needle: a UTF-8 byte substring.
    static func containsBytes(_ haystack: String, _ needle: String) -> Bool {
        let bytes = Array(haystack.utf8)
        return !bytes.byteOccurrences(of: Array(needle.utf8)).isEmpty || needle.isEmpty
    }

    /// `str::trim`.
    static func trim(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
        let last = scalars.lastIndex(where: { !isWhitespace($0) })!
        return String(scalars[first...last])
    }

    /// `str::trim().is_empty()`.
    static func isBlank(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isWhitespace)
    }

    /// `str::chars().count()`.
    static func charCount(_ text: String) -> Int {
        text.unicodeScalars.count
    }

    /// `str::split_whitespace().count()`.
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

    /// Receipt tokens: split on every non-alphanumeric scalar, drop empty
    /// pieces, lowercase each scalar without context (so a capital sigma
    /// always becomes σ), the contract the app's word-boundary resolver
    /// shares.
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
    /// Every start offset at which `needle` occurs as a contiguous run.
    /// Tokens compare by their UTF-8 bytes, as Rust strings do; Swift's own
    /// `==` treats canonically equivalent spellings (a precomposed syllable
    /// and its jamo sequence) as equal and would locate receipts the services
    /// reject.
    func occurrences(of needle: [String]) -> [Int] {
        guard !needle.isEmpty, needle.count <= count else { return [] }
        return (0...(count - needle.count)).filter { matchesRun(needle, at: $0) }
    }

    /// Rust `slice.windows(n).any(|w| w == needle)` for a non-empty needle.
    func containsRun(_ needle: [String]) -> Bool {
        guard !needle.isEmpty, needle.count <= count else { return false }
        return (0...(count - needle.count)).contains { matchesRun(needle, at: $0) }
    }

    private func matchesRun(_ needle: [String], at start: Int) -> Bool {
        for offset in needle.indices where !self[start + offset].utf8.elementsEqual(needle[offset].utf8) {
            return false
        }
        return true
    }
}
