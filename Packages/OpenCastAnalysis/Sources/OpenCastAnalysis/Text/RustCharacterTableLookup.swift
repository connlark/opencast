/// Sorted, non-overlapping inclusive scalar ranges with binary search.
struct ScalarRanges: Sendable {
    private let starts: [UInt32]
    private let ends: [UInt32]

    /// `pairs` is `first, last, first, last, …` in ascending order.
    init(pairs: [UInt32]) {
        starts = stride(from: 0, to: pairs.count, by: 2).map { pairs[$0] }
        ends = stride(from: 1, to: pairs.count, by: 2).map { pairs[$0] }
    }

    func contains(_ value: UInt32) -> Bool {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= value {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 && value <= ends[low - 1]
    }
}

extension RustCharacterTables {
    static let alphanumericRanges = ScalarRanges(pairs: alphanumeric)
    static let whitespaceRanges = ScalarRanges(pairs: whitespace)

    static let lowercaseMap: [UInt32: [Unicode.Scalar]] = {
        var map: [UInt32: [Unicode.Scalar]] = [:]
        var index = 0
        while index < lowercase.count {
            let scalar = lowercase[index]
            let count = Int(lowercase[index + 1])
            map[scalar] = lowercase[(index + 2)..<(index + 2 + count)].compactMap(Unicode.Scalar.init)
            index += 2 + count
        }
        return map
    }()
}
