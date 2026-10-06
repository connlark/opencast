/// Gapped line numbers for the episode lines. An answer listing a run of
/// matching episodes oldest first counts down through consecutive numbers,
/// which Apple's recitation check declines; numbers that rise by 1–3 at
/// random never form a countdown, and the answer maps back through the same
/// table.
nonisolated enum PlaylistOrganizerLineNumbers {
    /// index -> line number for `indices` (any order; numbered in ascending index order): first number 1...9,
    /// then +1...3 each, from SplitMix64(seed). Pure and deterministic for a seed.
    static func gapped(for indices: [Int], seed: UInt64) -> [Int: Int] {
        var generator = SplitMix64(seed: seed)
        var numbers: [Int: Int] = [:]
        var number = 0
        for index in Set(indices).sorted() {
            number += numbers.isEmpty
                ? Int.random(in: 1...9, using: &generator)
                : Int.random(in: 1...3, using: &generator)
            numbers[index] = number
        }
        return numbers
    }

    /// A fresh seed for a request that didn't pin one.
    static func randomSeed() -> UInt64 {
        UInt64.random(in: .min ... .max)
    }
}

/// Steele, Lea and Flood's SplitMix64: tiny, fast and fully determined by its
/// seed, which the system generator is not.
private nonisolated struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
