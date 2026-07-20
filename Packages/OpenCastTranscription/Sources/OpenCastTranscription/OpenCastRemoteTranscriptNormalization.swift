import Foundation

/// The bakeoff transcript normalization, shared by the app-side mapper and
/// tests so the Swift side reproduces the server's normalized transcript
/// hash bit-for-bit: lowercase, apostrophes removed, digit-grouping commas
/// collapsed, every other non-`[a-z0-9 ]` character replaced by a space,
/// whitespace-split. The hash is SHA-256 of the tokens joined with single
/// spaces.
public enum OpenCastRemoteTranscriptNormalization {
    public static func normalizedTokens(_ text: String) -> [String] {
        var value = text.lowercased()
        value = value.replacing("\u{2018}", with: "")
        value = value.replacing("\u{2019}", with: "")
        value = value.replacing("'", with: "")
        value = collapseDigitGroupingCommas(in: value)
        value = String(value.map { character in
            isNormalizedCharacter(character) ? character : " "
        })
        return value.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public static func normalizedTranscriptSHA256(_ text: String) -> String {
        OpenCastSHA256.hash(Data(normalizedTokens(text).joined(separator: " ").utf8))
    }

    private static func isNormalizedCharacter(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character) || character == " "
    }

    private static func collapseDigitGroupingCommas(in text: String) -> String {
        // Exact mirror of python re.sub(r"(\d),(\d)", r"\1\2", ...):
        // non-overlapping left-to-right matches of digit-comma-digit, and the
        // matched trailing digit is consumed, so it cannot anchor the next
        // match ("1,2,3" becomes "12,3", not "123").
        let characters = Array(text)
        var result = ""
        result.reserveCapacity(characters.count)
        var index = 0
        while index < characters.count {
            if index + 2 < characters.count,
               isASCIIDigit(characters[index]),
               characters[index + 1] == ",",
               isASCIIDigit(characters[index + 2]) {
                result.append(characters[index])
                result.append(characters[index + 2])
                index += 3
                continue
            }
            result.append(characters[index])
            index += 1
        }
        return result
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character)
    }
}
