import Foundation

/// Normalizes RSS 2.0 channel `<language>` values (BCP-47-ish tags like
/// `en`, `en-us`, `de-DE`). Locale equivalence is resolved downstream by the
/// speech stack; this only rejects values that are not language tags at all.
public enum RSSLanguageNormalizer {
    public static func normalized(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed.count <= 35
        else {
            return nil
        }

        let subtags = trimmed.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "-" || $0 == "_" }
        )
        guard let primary = subtags.first,
              (2...8).contains(primary.count),
              primary.allSatisfy(isASCIILetter),
              subtags.dropFirst().allSatisfy({ subtag in
                  (1...8).contains(subtag.count) && subtag.allSatisfy(isASCIILetterOrDigit)
              })
        else {
            return nil
        }

        return trimmed
    }

    private static func isASCIILetter(_ character: Character) -> Bool {
        character.isASCII && character.isLetter
    }

    private static func isASCIILetterOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }
}
