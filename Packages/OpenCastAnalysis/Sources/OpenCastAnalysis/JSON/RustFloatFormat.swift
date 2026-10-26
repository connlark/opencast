/// Text forms of binary64 values exactly as the Rust services print them.
public enum RustFloatFormat {
    /// The shortest round-trip digits of a finite, nonzero magnitude:
    /// `value == digits × 10^exponent` after decimal rounding, with no
    /// leading or trailing zeros in `digits`.
    static func shortestDigits(_ magnitude: Double) -> (digits: [UInt8], exponent: Int) {
        let text = magnitude.description
        var mantissa = Substring(text)
        var exponent = 0
        if let marker = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = text[..<marker]
            exponent = Int(text[text.index(after: marker)...])!
        }
        var digits: [UInt8] = []
        var fractionDigits = 0
        var seenPoint = false
        for character in mantissa {
            if character == "." {
                seenPoint = true
                continue
            }
            digits.append(character.asciiValue! - UInt8(ascii: "0"))
            if seenPoint { fractionDigits += 1 }
        }
        exponent -= fractionDigits
        while digits.count > 1, digits.last == 0 {
            digits.removeLast()
            exponent += 1
        }
        while digits.count > 1, digits.first == 0 {
            digits.removeFirst()
        }
        return (digits, exponent)
    }

    /// The float layout `serde_json` writes (its `zmij` formatter): fixed
    /// notation when the leading digit's decimal exponent is in -5...15
    /// (`1.0`, `0.00001`, `1000000000000000.0`, `12.34`), otherwise
    /// `d.ddde+N` / `de-N` with the shortest round-trip digits.
    public static func serdeJSON(_ value: Double) -> String {
        precondition(value.isFinite)
        var result = value.sign == .minus ? "-" : ""
        if value == 0 { return result + "0.0" }
        let (digits, k) = shortestDigits(value.magnitude)
        let text = String(decoding: digits.map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
        let length = digits.count
        let scientificExponent = length + k - 1
        if (-5...15).contains(scientificExponent) {
            if length - 1 <= scientificExponent {
                result += text + String(repeating: "0", count: scientificExponent + 1 - length) + ".0"
            } else if scientificExponent >= 0 {
                let split = text.index(text.startIndex, offsetBy: scientificExponent + 1)
                result += text[..<split] + "." + text[split...]
            } else {
                result += "0." + String(repeating: "0", count: -scientificExponent - 1) + text
            }
            return result
        }
        let first = text.index(after: text.startIndex)
        result += text[..<first]
        if length > 1 { result += "." + text[first...] }
        result += scientificExponent >= 0 ? "e+" : "e-"
        result += String(scientificExponent.magnitude)
        return result
    }

    /// Rust's `{}` Display for f64: shortest round-trip digits, never in
    /// exponent form, no `.0` on integral values.
    public static func display(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        var result = value.sign == .minus ? "-" : ""
        if value == 0 { return result + "0" }
        let (digits, k) = shortestDigits(value.magnitude)
        let text = String(decoding: digits.map { $0 + UInt8(ascii: "0") }, as: UTF8.self)
        let kk = digits.count + k
        if k >= 0 {
            result += text + String(repeating: "0", count: k)
        } else if kk > 0 {
            let split = text.index(text.startIndex, offsetBy: kk)
            result += text[..<split] + "." + text[split...]
        } else {
            result += "0." + String(repeating: "0", count: -kk) + text
        }
        return result
    }

    /// Rust's `{:.N}` for f64: the exact binary value rounded to `N` decimal
    /// places, ties to even.
    public static func fixed(_ value: Double, places: Int) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let negative = value.sign == .minus
        let magnitude = value.magnitude
        // magnitude == significand × 2^exponent exactly.
        let significand = magnitude == 0 ? 0 : magnitude.significandBitPattern
            | (magnitude.isNormal ? (1 << 52) : 0)
        let exponent = magnitude == 0 ? 0 : (magnitude.isNormal
            ? Int(magnitude.exponentBitPattern) - 1075 : -1074)
        var scaled = BigUInt(significand)
        for _ in 0..<places { scaled.multiply(by: 10) }
        var units: BigUInt
        if exponent >= 0 {
            scaled.shiftLeft(exponent)
            units = scaled
        } else {
            let shift = -exponent
            units = scaled.shiftedRight(shift)
            var remainder = scaled
            remainder.subtract(units.shiftedLeft(shift))
            let half = BigUInt(1).shiftedLeft(shift - 1)
            let order = remainder.compare(half)
            if order > 0 || (order == 0 && units.isOdd) {
                units.add(1)
            }
        }
        var decimal = units.decimalString()
        if places > 0 {
            if decimal.count <= places {
                decimal = String(repeating: "0", count: places - decimal.count + 1) + decimal
            }
            decimal.insert(".", at: decimal.index(decimal.endIndex, offsetBy: -places))
        }
        return (negative ? "-" : "") + decimal
    }
}

/// Just enough arbitrary-precision arithmetic for exact decimal rounding.
struct BigUInt {
    /// Little-endian 32-bit limbs.
    private(set) var limbs: [UInt32]

    init(_ value: UInt64) {
        limbs = [UInt32(truncatingIfNeeded: value), UInt32(truncatingIfNeeded: value >> 32)]
        normalize()
    }

    private mutating func normalize() {
        while limbs.count > 1, limbs.last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.count == 1 && limbs[0] == 0 }
    var isOdd: Bool { limbs[0] & 1 == 1 }

    mutating func multiply(by factor: UInt32) {
        var carry: UInt64 = 0
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(truncatingIfNeeded: product)
            carry = product >> 32
        }
        if carry > 0 { limbs.append(UInt32(carry)) }
        normalize()
    }

    mutating func add(_ value: UInt32) {
        var carry = UInt64(value)
        var index = 0
        while carry > 0 {
            if index == limbs.count { limbs.append(0) }
            let sum = UInt64(limbs[index]) + carry
            limbs[index] = UInt32(truncatingIfNeeded: sum)
            carry = sum >> 32
            index += 1
        }
    }

    /// Requires `self >= other`.
    mutating func subtract(_ other: BigUInt) {
        var borrow: Int64 = 0
        for index in limbs.indices {
            let rhs = index < other.limbs.count ? Int64(other.limbs[index]) : 0
            var difference = Int64(limbs[index]) - rhs - borrow
            borrow = 0
            if difference < 0 {
                difference += 1 << 32
                borrow = 1
            }
            limbs[index] = UInt32(difference)
        }
        normalize()
    }

    mutating func shiftLeft(_ bits: Int) {
        self = shiftedLeft(bits)
    }

    func shiftedLeft(_ bits: Int) -> BigUInt {
        guard bits > 0, !isZero else { return self }
        let limbShift = bits / 32
        let bitShift = bits % 32
        var result = [UInt32](repeating: 0, count: limbShift)
        var carry: UInt32 = 0
        for limb in limbs {
            result.append(bitShift == 0 ? limb : (limb << bitShift) | carry)
            carry = bitShift == 0 ? 0 : limb >> (32 - bitShift)
        }
        if carry > 0 { result.append(carry) }
        var value = BigUInt(0)
        value.limbs = result
        value.normalize()
        return value
    }

    func shiftedRight(_ bits: Int) -> BigUInt {
        let limbShift = bits / 32
        let bitShift = bits % 32
        guard limbShift < limbs.count else { return BigUInt(0) }
        var result: [UInt32] = []
        for index in limbShift..<limbs.count {
            var limb = limbs[index] >> bitShift
            if bitShift > 0, index + 1 < limbs.count {
                limb |= limbs[index + 1] << (32 - bitShift)
            }
            result.append(limb)
        }
        var value = BigUInt(0)
        value.limbs = result
        value.normalize()
        return value
    }

    func compare(_ other: BigUInt) -> Int {
        if limbs.count != other.limbs.count { return limbs.count < other.limbs.count ? -1 : 1 }
        for index in limbs.indices.reversed() where limbs[index] != other.limbs[index] {
            return limbs[index] < other.limbs[index] ? -1 : 1
        }
        return 0
    }

    func decimalString() -> String {
        var value = self
        var digits: [UInt8] = []
        repeat {
            var remainder: UInt64 = 0
            for index in value.limbs.indices.reversed() {
                let current = (remainder << 32) | UInt64(value.limbs[index])
                value.limbs[index] = UInt32(current / 10)
                remainder = current % 10
            }
            value.normalize()
            digits.append(UInt8(remainder) + UInt8(ascii: "0"))
        } while !value.isZero
        return String(decoding: digits.reversed(), as: UTF8.self)
    }
}
