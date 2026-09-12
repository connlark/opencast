import Foundation

nonisolated enum EpisodeAdAnalysisJobHandle {
    static func fingerprint(_ handle: String) -> String? {
        let value: String
        if handle.hasPrefix("a3.") {
            let parts = handle.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, (1...24).contains(parts[1].utf8.count),
                  parts[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
            else { return nil }
            value = String(parts[2])
        } else { value = handle }
        guard (8...128).contains(value.utf8.count), value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0)
        }) else { return nil }
        return value
    }

    static func matches(_ handle: String, fingerprint expected: String) -> Bool {
        fingerprint(handle) == expected
    }

    static func sameInput(_ lhs: String, _ rhs: String) -> Bool {
        guard let first = fingerprint(lhs), let second = fingerprint(rhs) else { return false }
        return first == second
    }
}
