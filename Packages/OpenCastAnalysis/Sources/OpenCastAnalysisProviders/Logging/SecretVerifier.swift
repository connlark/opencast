import Foundation
import OpenCastAnalysis

/// The authority on whether text may leave the provider layer. The
/// redactor (``RedactingLogger``) is best effort; every sink runs this
/// verifier on what the redactor produced and fails closed on any hit, so
/// the guarantee rests here, not on the redactor being complete.
///
/// Two contracts, one per kind of sink:
///
/// - **App sinks** (log lines, send records, observers) carry only closed
///   vocabularies and numbers by construction. ``verifyAppText(_:)``
///   checks that no registered secret survives whole (after normalising)
///   and no key-shaped run remains. It deliberately does not check 4-scalar
///   windows: a fixed word that happened to equal a key fragment would
///   suppress that line type for good, and a closed vocabulary cannot carry
///   a fragment anyway.
/// - **Recorder sinks** (every file the live tool writes) carry provider
///   text. ``verifyRecordedText(_:)``, ``verifyRecordedJSON(_:)`` and
///   ``verifyRecordedArtifact(_:)`` look for any 4-scalar window of any
///   registered secret, outside the secret's documented public prefix (a
///   key prefix such as `sk-proj-` is public, not secret, and its windows
///   match words such as "project").
///
/// The decoding contract for recorder sinks, the finite list a recording is
/// verified through: the JSON parser's escapes (an unpaired surrogate fails
/// closed); JSON nested in string values (depth 4, 256 KiB in all); in each
/// string value and member name, `\uXXXX` and short escapes, percent
/// encoding, numeric HTML entities of up to 64 digits (leading zeros, `;`
/// optional) and the common named ones, and base64 or base64url runs of six
/// or more symbols (the fewest that decode to four bytes), split at
/// padding and read at each of the four group alignments, so an encoding
/// placed after other base64 characters or after another padded encoding
/// is read at its own alignment, and read again with format characters and
/// compatibility forms removed but case kept; normalisation (below) before
/// and after every decoding, so the two compose in either order; up to four decoding
/// layers. A candidate still decodable at the fourth layer, a malformed
/// encoding, a combining run past 32, an expansion past four times, the
/// work bound (16 times the input plus 64 KiB) or any depth bound fails
/// closed: a bound never accepts. The whole artifact's bytes are then
/// checked as they stand, numbers included. A registered secret that
/// cannot itself be normalised within the bounds makes every verification
/// fail closed.
///
/// Normalisation, the same for secrets and candidates: compatibility
/// decomposition (NFKD), full case folding, NFKD again, then removal of
/// format (Cf), default-ignorable, nonspacing (Mn) and enclosing (Me)
/// characters. Decomposing before stripping matters: composing first would
/// turn `a` + U+0301 into `á` and hide the fragment. More than 32
/// consecutive combining marks, or an expansion past four times the input,
/// fails closed. Candidates are checked both as normalised and with every
/// masking run (`*`, `•`, `●`, `…`, runs of two or more dots and the like,
/// and runs of four or more `x` after a key prefix) collapsed to one marker.
public struct SecretVerifier: Sendable {
    public enum Verdict: Sendable, Hashable {
        case clean
        /// A registered secret, or a fragment of one, survives.
        case secretFragment
        /// A bound was reached before safety could be established.
        case exhausted
    }

    struct Window: Hashable, Sendable {
        let a: UInt32
        let b: UInt32
        let c: UInt32
        let d: UInt32

        init(_ scalars: ArraySlice<Unicode.Scalar>) {
            let start = scalars.startIndex
            a = scalars[start].value
            b = scalars[start + 1].value
            c = scalars[start + 2].value
            d = scalars[start + 3].value
        }
    }

    public static let windowLength = 4
    /// Member names whose value is a credential whatever it holds; such a
    /// member passes only when its value is null or already `[REDACTED]`.
    public static let credentialNames: Set<String> = [
        "authorization", "x-goog-api-key", "x-api-key", "api_key", "api-key", "apikey", "key", "token",
        "access_token", "secret", "password",
    ]
    static let maximumNestedDepth = 4
    static let maximumNestedBytes = 256 * 1024
    static let maximumJSONDepth = 64
    static let maximumDecodingLayers = 4

    let windows: Set<Window>
    let wholeSecrets: [[Unicode.Scalar]]
    /// A registered secret could not be normalised within the bounds, or is
    /// shorter than a window once normalised (no fragment contract can
    /// hold for it: it would match noise in any decoding). A bound never
    /// removes protection: every verification then fails closed.
    let registrationFailed: Bool

    public init(secrets: [String]) {
        var windows: Set<Window> = []
        var whole: [[Unicode.Scalar]] = []
        var failed = false
        // Deduplicated by bytes: hashing a String normalises it, which is
        // superlinear on a long run of combining marks, and a key is
        // checked against the bounds before anything else reads it.
        var registered: Set<[UInt8]> = []
        for secret in secrets where !secret.isEmpty && registered.insert(Array(secret.utf8)).inserted {
            guard let normalised = SecretNormalization.stripped(secret), !normalised.isEmpty else {
                failed = true
                continue
            }
            whole.append(normalised)
            let publicPrefix = SecretNormalization.publicPrefixLength(of: normalised)
            guard normalised.count >= Self.windowLength else {
                failed = true
                continue
            }
            for start in 0...(normalised.count - Self.windowLength) where start + Self.windowLength > publicPrefix {
                windows.insert(Window(normalised[start..<(start + Self.windowLength)]))
            }
        }
        self.windows = windows
        wholeSecrets = whole
        registrationFailed = failed
    }

    public var isEmpty: Bool { wholeSecrets.isEmpty && !registrationFailed }

    // MARK: App sinks

    /// For text built from closed vocabularies and numbers: no registered
    /// secret survives whole, normalised, and no key-shaped run remains.
    public func verifyAppText(_ text: String) -> Verdict {
        guard !registrationFailed else { return .exhausted }
        if RedactingLogger.containsKeyShape(text) { return .secretFragment }
        guard !wholeSecrets.isEmpty else { return .clean }
        guard let normalised = SecretNormalization.stripped(text) else { return .exhausted }
        for secret in wholeSecrets where LinearMatch.contains(secret, in: normalised) {
            return .secretFragment
        }
        return .clean
    }

    // MARK: Recorder sinks

    /// Free text bound for a recording, in every supported decoding.
    public func verifyRecordedText(_ text: String) -> Verdict {
        guard !registrationFailed else { return .exhausted }
        var budget = Budget(text: text)
        return verifyText(text, depth: 0, nested: 0, budget: &budget)
    }

    /// A parsed JSON value bound for a recording: every member name and
    /// string, nested JSON in strings, credential-named members.
    public func verifyRecordedJSON(_ value: JSONValue) -> Verdict {
        guard !registrationFailed else { return .exhausted }
        var budget = Budget(value: value)
        return verifyJSON(value, depth: 0, nested: 0, budget: &budget)
    }

    /// The serialized bytes of a whole artifact: parsed and verified by
    /// structure, and verified again as text, numbers included. Anything
    /// that is not JSON is not an artifact the recorder may write.
    public func verifyRecordedArtifact(_ bytes: String) -> Verdict {
        guard !registrationFailed else { return .exhausted }
        let value: JSONValue
        switch BoundedJSON.parse(bytes, maximumDepth: Self.maximumJSONDepth) {
        case .value(let parsed): value = parsed
        case .tooDeep: return .exhausted
        case .invalid: return .secretFragment
        }
        var budget = Budget(text: bytes)
        let structure = verifyJSON(value, depth: 0, nested: 0, budget: &budget)
        guard structure == .clean else { return structure }
        // The bytes as they stand, numbers and punctuation included. The
        // contract's decodings apply to values, and every value was just
        // verified through them.
        guard let normalised = SecretNormalization.stripped(bytes) else { return .exhausted }
        return hasWindow(normalised) || hasWindow(SecretNormalization.collapsed(normalised))
            ? .secretFragment
            : .clean
    }

    /// The work one verification may do: bytes of candidate text across
    /// every decoding (each candidate costs at least one), and bytes of
    /// nested JSON decoded from strings.
    struct Budget {
        var bytes: Int
        var nested = 0

        /// The work one verification may do: 16 times the bytes verified,
        /// plus 64 KiB.
        static func workBound(bytes: Int) -> Int {
            16 * bytes + 64 * 1024
        }

        init(text: String) {
            bytes = Self.workBound(bytes: text.utf8.count)
        }

        /// For a JSON value, the bytes of its serialized form.
        init(value: JSONValue) {
            bytes = Self.workBound(bytes: JSONWriter.byteCount(value))
        }

        mutating func spend(_ count: Int) -> Bool {
            bytes -= max(count, 1)
            return bytes >= 0
        }

        mutating func nestedBytes(_ count: Int) -> Bool {
            nested += count
            return nested <= SecretVerifier.maximumNestedBytes
        }
    }

    /// One bounded work queue over the candidate and everything it decodes
    /// to. Each candidate is normalised (case folded) for the fragment
    /// check; every decoder reads the candidate and its case-kept
    /// normalised form (compatibility forms and format characters removed,
    /// case kept, so fullwidth `％６３` decodes and base64 inside it keeps
    /// its case), so normalising and decoding compose in either order; and
    /// each of those forms that is JSON is verified by structure, inside
    /// the same budget. A candidate still decodable at the layer limit, a
    /// malformed encoding, nesting past the bounds or the work bound fails
    /// closed: a bound never accepts.
    func verifyText(_ text: String, depth: Int, nested: Int, budget: inout Budget) -> Verdict {
        guard !registrationFailed else { return .exhausted }
        // Breadth first, so a fragment at a shallow layer is found before
        // any deeper candidate can reach the layer limit.
        var pending: [(text: String, layer: Int)] = [(text, 0)]
        var next = 0
        // Keyed by bytes: hashing or comparing a String normalises it, which
        // is superlinear on long runs of combining marks.
        var seen: Set<[UInt8]> = [Array(text.utf8)]
        while next < pending.count {
            let (candidate, layer) = pending[next]
            next += 1
            guard budget.spend(candidate.utf8.count) else { return .exhausted }
            guard let normalised = SecretNormalization.stripped(candidate) else { return .exhausted }
            if hasWindow(normalised) || hasWindow(SecretNormalization.collapsed(normalised)) {
                return .secretFragment
            }
            var forms = [candidate]
            // ASCII has nothing for compatibility mapping or stripping to
            // change, so only other text has a case-kept form.
            if candidate.utf8.contains(where: { $0 >= 0x80 }) {
                guard let caseKept = SecretNormalization.stripped(candidate, foldingCase: false) else { return .exhausted }
                if !caseKept.elementsEqual(candidate.unicodeScalars) {
                    forms.append(String(String.UnicodeScalarView(caseKept)))
                }
            }
            for form in forms {
                let structure = verifyStructure(form, depth: depth, nested: nested, budget: &budget)
                guard structure == .clean else { return structure }
            }
            var successors: [String] = []
            for decoder in SecretDecodings.ordered {
                for form in forms {
                    switch decoder(form) {
                    case .unchanged:
                        continue
                    case .malformed:
                        return .exhausted
                    case .decoded(let decodings):
                        for decoded in decodings where seen.insert(Array(decoded.utf8)).inserted {
                            successors.append(decoded)
                        }
                    }
                }
            }
            guard !successors.isEmpty else { continue }
            guard layer < Self.maximumDecodingLayers else { return .exhausted }
            pending += successors.map { ($0, layer + 1) }
        }
        return .clean
    }

    /// A candidate that is a JSON document (it starts with `{`, `[` or `"`
    /// and parses) is verified by structure: four levels of JSON in strings
    /// and 256 KiB of it in all, its containers counted with the `depth`
    /// already around the string before it is parsed, since verification
    /// walks the value level by level. Past any bound, fail closed; text
    /// that is not JSON is only text.
    func verifyStructure(_ text: String, depth: Int, nested: Int, budget: inout Budget) -> Verdict {
        guard let first = text.unicodeScalars.first(where: { !" \t\r\n".unicodeScalars.contains($0) }),
              first == "{" || first == "[" || first == "\""
        else {
            return .clean
        }
        switch BoundedJSON.parse(text, maximumDepth: max(Self.maximumJSONDepth - depth, 0)) {
        case .invalid:
            return .clean
        case .tooDeep:
            return .exhausted
        case .value(let value):
            guard nested < Self.maximumNestedDepth else { return .exhausted }
            guard budget.spend(text.utf8.count), budget.nestedBytes(text.utf8.count) else { return .exhausted }
            return verifyJSON(value, depth: depth, nested: nested + 1, budget: &budget)
        }
    }

    /// `depth` counts the containers around `value`, across JSON held in
    /// strings: a container is the (`depth` + 1)th, and one past
    /// ``maximumJSONDepth`` fails closed, the count every entry point makes.
    func verifyJSON(_ value: JSONValue, depth: Int, nested: Int, budget: inout Budget) -> Verdict {
        switch value {
        case .string(let text):
            return verifyText(text, depth: depth, nested: nested, budget: &budget)
        case .unpairedSurrogateString, .tooDeepContainer:
            return .exhausted
        case .array(let values):
            guard depth < Self.maximumJSONDepth else { return .exhausted }
            for element in values {
                let verdict = verifyJSON(element, depth: depth + 1, nested: nested, budget: &budget)
                guard verdict == .clean else { return verdict }
            }
            return .clean
        case .object(let members):
            guard depth < Self.maximumJSONDepth else { return .exhausted }
            for member in members {
                guard !member.keyHasUnpairedSurrogate else { return .exhausted }
                let name = verifyText(member.key, depth: depth + 1, nested: nested, budget: &budget)
                guard name == .clean else { return name }
                if Self.isCredentialName(member.key), !Self.isRedactedOrNull(member.value) { return .secretFragment }
                let verdict = verifyJSON(member.value, depth: depth + 1, nested: nested, budget: &budget)
                guard verdict == .clean else { return verdict }
            }
            return .clean
        case .null, .bool, .number, .unrepresentableNumber:
            return .clean
        }
    }

    static func isCredentialName(_ name: String) -> Bool {
        guard let normalised = SecretNormalization.stripped(name) else { return true }
        return credentialNames.contains(String(String.UnicodeScalarView(normalised)))
    }

    static func isRedactedOrNull(_ value: JSONValue) -> Bool {
        switch value {
        case .null: true
        case .string(let text): text.utf8.elementsEqual(RedactingLogger.redacted.utf8)
        default: false
        }
    }

    func hasWindow(_ scalars: [Unicode.Scalar]) -> Bool {
        guard !windows.isEmpty, scalars.count >= Self.windowLength else { return false }
        for start in 0...(scalars.count - Self.windowLength) where windows.contains(Window(scalars[start..<(start + Self.windowLength)])) {
            return true
        }
        return false
    }

}

extension SecretVerifier: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    // The window set holds fragments of the secrets: never print it.
    public var description: String { "SecretVerifier(secrets: \(wholeSecrets.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["secretCount": wholeSecrets.count]) }
}

/// The normalisation both sides of the verifier use.
enum SecretNormalization {
    static let maximumCombiningRun = 32
    static let maximumExpansion = 4
    static let marker: Unicode.Scalar = "\u{FFFC}"
    /// Documented public key prefixes, normalised (case-folded).
    static let publicPrefixes: [[Unicode.Scalar]] = ["sk-proj-", "sk-ant-", "sk-", "aizasy", "aiza", "aq.", "pplx-"]
        .map { Array($0.unicodeScalars) }

    /// Scalars decomposed together. Foundation reorders a run of combining
    /// marks as a whole, superlinearly, and a scalar can become a mark only
    /// when decomposed (U+FF9E becomes U+3099), so no run can be bounded
    /// before decomposing; decomposing a chunk at a time bounds the cost of
    /// each run by the chunk instead. Marks are removed afterwards, so where
    /// a run is split does not change the result.
    static let chunkScalars = 64

    /// Whether `text` normalises within the bounds: no run of more than 32
    /// combining marks once decomposed, and no expansion past four times.
    static func withinCombiningBound(_ text: String) -> Bool {
        stripped(text) != nil
    }

    /// NFKD, full case folding, NFKD, then format, default-ignorable,
    /// nonspacing, enclosing and spacing combining characters removed.
    /// With `foldingCase` false, the same without the case folding (the form
    /// the decoders read). Computed a chunk of scalars at a time, ASCII
    /// without Foundation; `nil` past the bounds, checked as the
    /// decomposition is produced.
    static func stripped(_ text: String, foldingCase: Bool = true) -> [Unicode.Scalar]? {
        let scalars = Array(text.unicodeScalars)
        let limit = maximumExpansion * scalars.count + 16
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var combining = 0
        var total = 0
        func emit(_ scalar: Unicode.Scalar) -> Bool {
            total += 1
            guard total <= limit else { return false }
            let category = scalar.properties.generalCategory
            if category == .nonspacingMark || category == .enclosingMark || category == .spacingMark {
                combining += 1
                return combining <= maximumCombiningRun
            }
            combining = 0
            if category == .format || scalar.properties.isDefaultIgnorableCodePoint { return true }
            output.append(scalar)
            return true
        }
        var start = 0
        while start < scalars.count {
            let end = min(start + chunkScalars, scalars.count)
            let chunk = scalars[start..<end]
            if chunk.allSatisfy(\.isASCII) {
                for scalar in chunk {
                    let folded = foldingCase && ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 0x20)! : scalar
                    guard emit(folded) else { return nil }
                }
            } else {
                // A run of marks within one chunk is at most the chunk long,
                // so Foundation's reordering of it is bounded too.
                let piece = String(String.UnicodeScalarView(chunk))
                let decomposed = foldingCase
                    ? piece.decomposedStringWithCompatibilityMapping
                        .folding(options: [.caseInsensitive], locale: nil)
                        .decomposedStringWithCompatibilityMapping
                    : piece.decomposedStringWithCompatibilityMapping
                for scalar in decomposed.unicodeScalars {
                    guard emit(scalar) else { return nil }
                }
            }
            start = end
        }
        return output
    }

    static let maskScalars: Set<Unicode.Scalar> = [
        "*", "\u{2022}", "\u{25CF}", "\u{00B7}", "\u{2219}", "\u{2217}", "\u{22EF}", "\u{25A0}", "\u{25AA}",
        "\u{2588}", "\u{25CB}", "\u{25E6}", "\u{2027}", "\u{2026}",
    ]

    /// Every masking run collapsed to one marker: masking characters, runs
    /// of two or more dots, and runs of four or more `x` right after a key
    /// prefix.
    static func collapsed(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if maskScalars.contains(scalar) || scalar == "." {
                var end = index
                var masks = 0
                while end < scalars.count, maskScalars.contains(scalars[end]) || scalars[end] == "." {
                    if scalars[end] != "." { masks += 1 }
                    end += 1
                }
                if masks > 0 || end - index >= 2 {
                    if output.last != marker { output.append(marker) }
                } else {
                    output.append(contentsOf: scalars[index..<end])
                }
                index = end
                continue
            }
            if scalar == "x", publicPrefixes.contains(where: { output.suffix($0.count).elementsEqual($0) }) {
                var end = index
                while end < scalars.count, scalars[end] == "x" { end += 1 }
                if end - index >= 4 {
                    output.append(marker)
                    index = end
                    continue
                }
            }
            output.append(scalar)
            index += 1
        }
        return output
    }

    /// The length of the documented public prefix a normalised secret
    /// starts with, if any.
    static func publicPrefixLength(of secret: [Unicode.Scalar]) -> Int {
        publicPrefixes.first { secret.starts(with: $0) }?.count ?? 0
    }
}

/// Knuth-Morris-Pratt over scalars: linear in text plus pattern.
enum LinearMatch {
    static func failure(_ pattern: [Unicode.Scalar]) -> [Int] {
        var table = [Int](repeating: 0, count: pattern.count)
        var length = 0
        var index = 1
        while index < pattern.count {
            if pattern[index] == pattern[length] {
                length += 1
                table[index] = length
                index += 1
            } else if length > 0 {
                length = table[length - 1]
            } else {
                index += 1
            }
        }
        return table
    }

    /// Every occurrence of `pattern` in `text`, overlapping ones included.
    static func ranges(of pattern: [Unicode.Scalar], in text: [Unicode.Scalar]) -> [Range<Int>] {
        guard !pattern.isEmpty, text.count >= pattern.count else { return [] }
        let table = failure(pattern)
        var ranges: [Range<Int>] = []
        var matched = 0
        for (index, scalar) in text.enumerated() {
            while matched > 0, scalar != pattern[matched] { matched = table[matched - 1] }
            if scalar == pattern[matched] { matched += 1 }
            if matched == pattern.count {
                ranges.append((index + 1 - pattern.count)..<(index + 1))
                matched = table[matched - 1]
            }
        }
        return ranges
    }

    static func contains(_ pattern: [Unicode.Scalar], in text: [Unicode.Scalar]) -> Bool {
        !ranges(of: pattern, in: text).isEmpty
    }
}

/// The decodings a recorded string is verified through, each bounded and
/// each reporting a malformed input (which fails closed).
enum SecretDecodings {
    enum Result: Equatable {
        case unchanged
        case malformed
        /// Each decoding a separate candidate, never merged: a base64 text
        /// yields one per run, alignment and segment.
        case decoded([String])
    }

    /// Every decoder, each applied to the raw candidate and its case-kept
    /// normalised form.
    static let ordered: [@Sendable (String) -> Result] = [jsonUnescaped, percentDecoded, htmlDecoded, base64Decoded]

    /// `\uXXXX` and the short escapes in text that is not itself parsed as
    /// JSON. A `\u` followed by one to three hex digits, or an unpaired
    /// surrogate, is malformed; a `\u` followed by no hex digit is text
    /// (`C:\users`).
    @Sendable static func jsonUnescaped(_ text: String) -> Result {
        guard text.contains("\\") else { return .unchanged }
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var changed = false
        /// The hex digits from `at`, up to four.
        func hexDigits(_ at: Int) -> Int {
            var count = 0
            while count < 4, at + count < scalars.count, scalars[at + count].properties.isASCIIHexDigit { count += 1 }
            return count
        }
        func hex(_ at: Int) -> UInt32? {
            guard hexDigits(at) == 4 else { return nil }
            return UInt32(String(String.UnicodeScalarView(scalars[at..<(at + 4)])), radix: 16)
        }
        while index < scalars.count {
            guard scalars[index] == "\\", index + 1 < scalars.count else {
                output.append(scalars[index])
                index += 1
                continue
            }
            let next = scalars[index + 1]
            switch next {
            case "u":
                guard let unit = hex(index + 2) else {
                    if hexDigits(index + 2) > 0 { return .malformed }
                    output.append(scalars[index])
                    index += 1
                    continue
                }
                if (0xD800...0xDBFF).contains(unit) {
                    guard index + 12 <= scalars.count, scalars[index + 6] == "\\", scalars[index + 7] == "u",
                          let low = hex(index + 8), (0xDC00...0xDFFF).contains(low)
                    else {
                        return .malformed
                    }
                    output.append(Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))!)
                    index += 12
                } else if (0xDC00...0xDFFF).contains(unit) {
                    return .malformed
                } else {
                    output.append(Unicode.Scalar(unit)!)
                    index += 6
                }
                changed = true
            case "n", "t", "r", "b", "f", "\"", "\\", "/":
                let map: [Unicode.Scalar: Unicode.Scalar] = ["n": "\n", "t": "\t", "r": "\r", "b": "\u{08}", "f": "\u{0C}"]
                output.append(map[next] ?? next)
                index += 2
                changed = true
            default:
                output.append(scalars[index])
                index += 1
            }
        }
        return changed ? .decoded([String(output)]) : .unchanged
    }

    /// `%XX` sequences decoded as UTF-8 (invalid sequences replaced). A
    /// `%` that starts an escape and does not finish one is malformed: a hex
    /// digit then anything but a hex digit (`%1G`, `%4` at the end), or a
    /// letter or digit then a hex digit (`%G1`); a `%` before anything else
    /// is text (`50% off`, `%ok`).
    @Sendable static func percentDecoded(_ text: String) -> Result {
        guard text.contains("%") else { return .unchanged }
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var changed = false
        func value(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: byte - 0x30
            case 0x41...0x46: byte - 0x41 + 10
            case 0x61...0x66: byte - 0x61 + 10
            default: nil
            }
        }
        while index < bytes.count {
            if bytes[index] == 0x25 {
                let first: UInt8? = index + 1 < bytes.count ? bytes[index + 1] : nil
                let second: UInt8? = index + 2 < bytes.count ? bytes[index + 2] : nil
                if let first, let second, let high = value(first), let low = value(second) {
                    output.append(high << 4 | low)
                    index += 3
                    changed = true
                    continue
                }
                let alphanumeric = { (byte: UInt8) in (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte) }
                if let first, value(first) != nil { return .malformed }
                if let first, let second, alphanumeric(first), value(second) != nil { return .malformed }
                output.append(bytes[index])
                index += 1
            } else if bytes[index] == 0x2B {
                output.append(0x20)
                index += 1
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return changed ? .decoded([String(decoding: output, as: UTF8.self)]) : .unchanged
    }

    /// The named references read: HTML's names for ASCII punctuation (the
    /// characters keys and encodings are made of) and no-break space, any
    /// letter case.
    static let namedEntities: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "lowbar": "_", "underbar": "_",
        "period": ".", "sol": "/", "bsol": "\\", "plus": "+", "equals": "=", "percnt": "%", "num": "#", "semi": ";",
        "colon": ":", "commat": "@", "dollar": "$", "excl": "!", "quest": "?", "lpar": "(", "rpar": ")", "ast": "*",
        "midast": "*", "comma": ",", "lsqb": "[", "rsqb": "]", "lbrack": "[", "rbrack": "]", "lcub": "{", "rcub": "}",
        "lbrace": "{", "rbrace": "}", "verbar": "|", "vert": "|", "grave": "`", "hat": "^", "tab": "\t", "newline": "\n",
    ]

    /// The longest numeric entity read (leading zeros included); a longer
    /// one is malformed and fails closed.
    static let maximumEntityDigits = 64

    /// Numeric entities (`&#115;`, `&#x73;`, any number of leading zeros,
    /// the `;` optional as HTML allows) and the common named ones, read in
    /// one forward pass. A numeric entity with no digits (`&#;`, `&#x;`) or
    /// past the bounds is malformed.
    @Sendable static func htmlDecoded(_ text: String) -> Result {
        guard text.contains("&") else { return .unchanged }
        let named = namedEntities
        let scalars = Array(text.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var changed = false
        func isHex(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isASCIIHexDigit }
        while index < scalars.count {
            guard scalars[index] == "&", index + 1 < scalars.count else {
                output.append(scalars[index])
                index += 1
                continue
            }
            if scalars[index + 1] == "#" {
                var cursor = index + 2
                let hex = cursor < scalars.count && (scalars[cursor] == "x" || scalars[cursor] == "X")
                if hex { cursor += 1 }
                let start = cursor
                while cursor < scalars.count, hex ? isHex(scalars[cursor]) : ("0"..."9").contains(scalars[cursor]) {
                    cursor += 1
                    guard cursor - start <= maximumEntityDigits else { return .malformed }
                }
                // `&#` starts a numeric entity: one without digits is malformed.
                guard cursor > start else { return .malformed }
                let digits = String(String.UnicodeScalarView(scalars[start..<cursor]))
                let trimmed = digits.drop { $0 == "0" }
                let value = trimmed.isEmpty ? 0 : UInt32(trimmed, radix: hex ? 16 : 10)
                guard let value, let scalar = Unicode.Scalar(value) else { return .malformed }
                output.append(scalar)
                if cursor < scalars.count, scalars[cursor] == ";" { cursor += 1 }
                index = cursor
                changed = true
                continue
            }
            var cursor = index + 1
            while cursor < scalars.count, cursor - index <= 8, scalars[cursor].properties.isAlphabetic, scalars[cursor].isASCII { cursor += 1 }
            if cursor < scalars.count, scalars[cursor] == ";",
               let scalar = named[String(String.UnicodeScalarView(scalars[(index + 1)..<cursor])).lowercased()] {
                output.append(scalar)
                index = cursor + 1
                changed = true
            } else {
                output.append(scalars[index])
                index += 1
            }
        }
        return changed ? .decoded([String(output)]) : .unchanged
    }

    /// The fewest base64 symbols that decode to four bytes, the shortest
    /// text a window can be.
    static let minimumBase64Symbols = 6

    /// Every run of base64 or base64url characters holding at least six
    /// symbols, split at its padding into segments and decoded at each of
    /// the four group alignments: for each alignment, every segment's
    /// groups from that offset, a short last group decoded as far as it
    /// goes. An encoding that follows other base64 characters, or another
    /// padded encoding, is read at its own alignment. Every run, alignment
    /// and segment is its own candidate; output that decodes to nothing is
    /// skipped.
    @Sendable static func base64Decoded(_ text: String) -> Result {
        let bytes = Array(text.utf8)
        func sextet(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x41...0x5A: byte - 0x41
            case 0x61...0x7A: byte - 0x61 + 26
            case 0x30...0x39: byte - 0x30 + 52
            case 0x2B, 0x2D: 62
            case 0x2F, 0x5F: 63
            default: nil
            }
        }
        let padding: UInt8 = 0x3D
        var decodings: [String] = []
        var segments: [[UInt8]] = []
        var index = 0
        while index < bytes.count {
            guard sextet(bytes[index]) != nil || bytes[index] == padding else {
                index += 1
                continue
            }
            segments.removeAll(keepingCapacity: true)
            var current: [UInt8] = []
            var symbols = 0
            while index < bytes.count {
                if let value = sextet(bytes[index]) {
                    current.append(value)
                    symbols += 1
                } else if bytes[index] == padding {
                    if !current.isEmpty { segments.append(current) }
                    current = []
                } else {
                    break
                }
                index += 1
            }
            if !current.isEmpty { segments.append(current) }
            guard symbols >= minimumBase64Symbols else { continue }
            func decode(_ segment: [UInt8], from alignment: Int, into output: inout [UInt8]) {
                var group = alignment
                while group + 1 < segment.count {
                    let available = min(4, segment.count - group)
                    let a = segment[group], b = segment[group + 1]
                    output.append(a << 2 | b >> 4)
                    if available >= 3 {
                        let c = segment[group + 2]
                        output.append((b & 0x0F) << 4 | c >> 2)
                        if available == 4 { output.append((c & 0x03) << 6 | segment[group + 3]) }
                    }
                    group += 4
                }
            }
            for alignment in 0..<4 {
                // The segments read in a row (encodings back to back), and,
                // when there are several, each segment on its own: every
                // one a candidate, so each is verified by structure alone.
                var joined: [UInt8] = []
                for segment in segments where segment.count > alignment {
                    var own: [UInt8] = []
                    decode(segment, from: alignment, into: &own)
                    joined += own
                    if segments.count > 1, !own.isEmpty { decodings.append(String(decoding: own, as: UTF8.self)) }
                }
                if !joined.isEmpty { decodings.append(String(decoding: joined, as: UTF8.self)) }
            }
        }
        return decodings.isEmpty ? .unchanged : .decoded(decodings)
    }
}
