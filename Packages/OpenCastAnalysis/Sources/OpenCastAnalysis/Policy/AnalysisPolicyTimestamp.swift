import Foundation

/// The one timestamp form a policy bundle may carry: canonical UTC
/// `YYYY-MM-DDTHH:MM:SSZ` with a real calendar date, hours 00-23 and minutes
/// and seconds 00-59. The generator enforces the same rule, and both sides are
/// tested against the gateway's shared timestamp cases, so a bundle that
/// passes publication always decodes here and nothing else does.
public enum AnalysisPolicyTimestamp {
    public static func date(from value: String) -> Date? {
        unixSeconds(from: value).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    public static func unixSeconds(from value: String) -> Int64? {
        let bytes = Array(value.utf8)
        guard bytes.count == 20,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: "T"), bytes[13] == UInt8(ascii: ":"),
              bytes[16] == UInt8(ascii: ":"), bytes[19] == UInt8(ascii: "Z")
        else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int64? {
            var result: Int64 = 0
            for byte in bytes[range] {
                guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
                result = result * 10 + Int64(byte - UInt8(ascii: "0"))
            }
            return result
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19)
        else {
            return nil
        }
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let monthDays: [Int64] = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...12).contains(month), (1...monthDays[Int(month - 1)]).contains(day),
              hour <= 23, minute <= 59, second <= 59
        else {
            return nil
        }
        // Days from the civil date (Howard Hinnant's algorithm), as the generator computes it.
        let shiftedYear = month <= 2 ? year - 1 : year
        let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
        let yearOfEra = shiftedYear - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468
        return days * 86_400 + hour * 3_600 + minute * 60 + second
    }
}
