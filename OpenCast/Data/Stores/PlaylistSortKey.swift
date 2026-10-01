/// Fractional ordering keys for playlist items, so moving one item rewrites
/// one row (a synced row per move, never a renumbered playlist).
///
/// A key is a non-empty base-36 fraction strictly between 0 and 1: its
/// symbols are the digits after the radix point, and it never ends in the
/// smallest symbol, so every value has exactly one spelling. The alphabet is
/// ASCII-ordered, so plain `String` `<` (or a `.lexical` sort descriptor)
/// orders keys by value; the default `.localizedStandard` comparator is
/// numeric-aware and misorders them.
nonisolated enum PlaylistSortKey {
    static let alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
    /// Head inserts grow a key by one symbol every few inserts; past this
    /// length the whole playlist is renumbered in one save.
    static let renumberThreshold = 64

    private static let symbols = Array(alphabet)
    private static let radix = symbols.count

    static func isValid(_ key: String) -> Bool {
        guard let lastSymbol = key.last, lastSymbol != symbols[0] else {
            return false
        }

        return key.allSatisfy { symbols.contains($0) }
    }

    /// A key strictly between `lower` and `upper`; nil `lower` means 0 and nil
    /// `upper` means 1.
    static func between(_ lower: String?, _ upper: String?) -> String {
        if let lower {
            precondition(isValid(lower), "Invalid playlist sort key \(lower)")
        }
        if let upper {
            precondition(isValid(upper), "Invalid playlist sort key \(upper)")
        }
        if let lower, let upper {
            precondition(lower < upper, "Playlist sort key \(lower) must precede \(upper)")
        }

        let lowerDigits = lower.map(digits(of:)) ?? []
        let upperDigits = upper.map(digits(of:))
        return string(from: midpoint(lowerDigits[...], upperDigits?[...]))
    }

    static func first(before head: String?) -> String {
        between(nil, head)
    }

    static func last(after tail: String?) -> String {
        between(tail, nil)
    }

    static func needsRenumbering(_ key: String) -> Bool {
        key.count > renumberThreshold
    }

    /// `count` evenly spaced, strictly increasing keys of the shortest length
    /// that fits them.
    static func renumbered(count: Int) -> [String] {
        precondition(count >= 0, "Cannot renumber a negative count")
        guard count > 0 else {
            return []
        }

        var length = 1
        var capacity = radix
        while capacity <= count {
            capacity *= radix
            length += 1
        }

        let step = capacity / (count + 1)
        return (1...count).map { position in
            var value = step * position
            var digits = [Int](repeating: 0, count: length)
            for index in digits.indices.reversed() {
                digits[index] = value % radix
                value /= radix
            }
            while digits.last == 0 {
                digits.removeLast()
            }
            return string(from: digits)
        }
    }

    /// The fraction-part midpoint from rocicorp's fractional-indexing: strip
    /// the common prefix (a missing lower digit reads as 0), then take the
    /// middle digit when the first digits are more than one apart; otherwise
    /// the upper's first digit alone when it has more digits, else keep the
    /// lower's first digit and recurse towards 1.
    private static func midpoint(_ lower: ArraySlice<Int>, _ upper: ArraySlice<Int>?) -> [Int] {
        if let upper {
            var prefixLength = 0
            while prefixLength < upper.count,
                  digit(at: prefixLength, in: lower) == upper[upper.startIndex + prefixLength] {
                prefixLength += 1
            }
            if prefixLength > 0 {
                return Array(upper.prefix(prefixLength))
                    + midpoint(lower.dropFirst(prefixLength), upper.dropFirst(prefixLength))
            }
        }

        let lowerFirst = lower.first ?? 0
        let upperFirst = upper?.first ?? radix
        if upperFirst - lowerFirst > 1 {
            return [(lowerFirst + upperFirst + 1) / 2]
        }
        if let upper, upper.count > 1 {
            return [upperFirst]
        }
        return [lowerFirst] + midpoint(lower.dropFirst(), nil)
    }

    private static func digit(at offset: Int, in digits: ArraySlice<Int>) -> Int {
        offset < digits.count ? digits[digits.startIndex + offset] : 0
    }

    private static func digits(of key: String) -> [Int] {
        key.compactMap { symbol in
            symbols.firstIndex(of: symbol)
        }
    }

    private static func string(from digits: [Int]) -> String {
        String(digits.map { symbols[$0] })
    }
}
