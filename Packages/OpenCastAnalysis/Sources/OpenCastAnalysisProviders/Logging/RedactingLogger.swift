import Foundation
import OpenCastAnalysis
import OSLog

/// Receives the redacted lines a ``RedactingLogger`` writes, for tests and
/// command-line tools.
public protocol AnalysisLogSink: Sendable {
    func write(_ line: String)
}

/// What a recorder may write for one artifact: the redacted JSON when
/// ``SecretVerifier`` proved it clean, otherwise a fixed placeholder.
public struct AnalysisSafeRecording: Sendable, Hashable {
    /// The bytes to write.
    public var text: String
    /// Whether `text` is the artifact (true) or a placeholder (false).
    public var recorded: Bool
    /// Why the artifact was suppressed: `secret_fragment`,
    /// `verification_bound` or `not_json`.
    public var reason: String?
}

/// The one logger of the provider layer, and the redaction every sink uses.
///
/// The redactor here is best effort and deliberately simple, every pass
/// linear: registered secrets matched exactly; masked key forms (a key
/// prefix touching a masking run, or four or more masking characters);
/// key-shaped runs; credential values after a credential name (quoted
/// values, `Basic` and `Bearer` whole values), standalone `Basic` and
/// `Bearer` values, and query parameters whose percent-decoded name is a
/// credential name; JSON by structure, keeping numbers. **It carries no
/// guarantee.** ``SecretVerifier`` does: every sink verifies what the
/// redactor produced and fails closed on any hit, so a log line becomes
/// `[REDACTED LINE]` and a recording becomes
/// `{"redacted": true, "reason": "secret_fragment"}`.
///
/// Log lines are an app sink: callers pass structured facts (closed
/// vocabularies and numbers), never a provider body or header, and the
/// verifier checks them for whole secrets and key shapes. Recordings are a
/// recorder sink, verified for every 4-scalar fragment in every supported
/// decoding.
public struct RedactingLogger: Sendable {
    public static let redacted = "[REDACTED]"
    public static let redactedLine = "[REDACTED LINE]"

    private let logger: Logger?
    private let sink: (any AnalysisLogSink)?
    private let secrets: [String]
    private let verifier: SecretVerifier

    /// - Parameters:
    ///   - subsystem: The unified logging subsystem; `nil` writes only to `sink`.
    ///   - secrets: Values never to print, such as the transport's key.
    public init(
        subsystem: String? = "OpenCastAnalysis",
        category: String = "AnalysisProviders",
        secrets: [String] = [],
        sink: (any AnalysisLogSink)? = nil
    ) {
        self.init(logger: subsystem.map { Logger(subsystem: $0, category: category) }, sink: sink, secrets: secrets)
    }

    /// The same logger, also redacting `secret`.
    public func redacting(_ secret: String) -> RedactingLogger {
        RedactingLogger(logger: logger, sink: sink, secrets: secrets + [secret])
    }

    private init(logger: Logger?, sink: (any AnalysisLogSink)?, secrets: [String]) {
        self.logger = logger
        self.sink = sink
        self.secrets = secrets.filter { !$0.isEmpty }
        verifier = SecretVerifier(secrets: self.secrets)
    }

    public func log(_ message: String) {
        let line = Self.safeLine(message, secrets: secrets, verifier: verifier)
        logger?.log("\(line, privacy: .public)")
        sink?.write(line)
    }

    // MARK: Sinks

    /// A line for an app sink: redacted, then verified; `[REDACTED LINE]`
    /// when the verifier finds anything.
    public static func safeLine(_ text: String, secrets: [String] = []) -> String {
        safeLine(text, secrets: secrets, verifier: SecretVerifier(secrets: secrets))
    }

    static func safeLine(_ text: String, secrets: [String], verifier: SecretVerifier) -> String {
        let line = redact(text, secrets: secrets)
        return verifier.verifyAppText(line) == .clean ? line : redactedLine
    }

    /// A recorder artifact from text: JSON is redacted by structure and
    /// verified; anything that is not JSON is never written as text.
    public static func safeRecording(_ text: String, secrets: [String]) -> AnalysisSafeRecording {
        let verifier = SecretVerifier(secrets: secrets)
        switch BoundedJSON.parse(text, maximumDepth: SecretVerifier.maximumJSONDepth) {
        case .value(let value):
            return safeRecording(value, secrets: secrets, verifier: verifier)
        case .tooDeep:
            return placeholder(reason: "verification_bound", bytes: nil, verifier: verifier)
        case .invalid:
            return placeholder(reason: "not_json", bytes: text.utf8.count, verifier: verifier)
        }
    }

    /// A recorder artifact from a JSON value: redacted by structure, then the
    /// serialized bytes verified as a whole, numbers included.
    public static func safeRecording(_ value: JSONValue, secrets: [String]) -> AnalysisSafeRecording {
        safeRecording(value, secrets: secrets, verifier: SecretVerifier(secrets: secrets))
    }

    static func safeRecording(_ value: JSONValue, secrets: [String], verifier: SecretVerifier) -> AnalysisSafeRecording {
        let text = JSONWriter.string(redactForRecording(value, secrets: secrets, verifier: verifier, depth: 0))
        switch verifier.verifyRecordedArtifact(text) {
        case .clean:
            return AnalysisSafeRecording(text: text, recorded: true, reason: nil)
        case .secretFragment:
            return placeholder(reason: "secret_fragment", bytes: nil, verifier: verifier)
        case .exhausted:
            return placeholder(reason: "verification_bound", bytes: nil, verifier: verifier)
        }
    }

    /// A recorder artifact built from structured fields (closed values,
    /// numbers and already verified text): verified whole as it stands and
    /// written unchanged, or replaced by a placeholder. Nothing is redacted,
    /// so what is written is exactly what was built.
    public static func verifiedRecording(_ value: JSONValue, verifier: SecretVerifier) -> AnalysisSafeRecording {
        let text = JSONWriter.string(value)
        switch verifier.verifyRecordedArtifact(text) {
        case .clean:
            return AnalysisSafeRecording(text: text, recorded: true, reason: nil)
        case .secretFragment:
            return placeholder(reason: "secret_fragment", bytes: nil, verifier: verifier)
        case .exhausted:
            return placeholder(reason: "verification_bound", bytes: nil, verifier: verifier)
        }
    }

    /// `{"redacted": true, "reason": …}`, with the byte count only when the
    /// count itself verifies.
    static func placeholder(reason: String, bytes: Int?, verifier: SecretVerifier) -> AnalysisSafeRecording {
        let members = [JSONMember("redacted", .bool(true)), JSONMember("reason", .string(reason))]
        if let bytes {
            let withBytes = JSONWriter.string(.object(members + [JSONMember("bytes", .integer(bytes))]))
            if verifier.verifyRecordedArtifact(withBytes) == .clean {
                return AnalysisSafeRecording(text: withBytes, recorded: false, reason: reason)
            }
        }
        return AnalysisSafeRecording(text: JSONWriter.string(.object(members)), recorded: false, reason: reason)
    }

    /// JSON by structure: each string and member name redacted as text and
    /// replaced whole when the verifier still flags it; credential-named
    /// members' values replaced; numbers, booleans and nulls kept.
    static func redactForRecording(_ value: JSONValue, secrets: [String], verifier: SecretVerifier, depth: Int) -> JSONValue {
        guard depth <= SecretVerifier.maximumJSONDepth else { return .string(redacted) }
        switch value {
        case .string(let text):
            let redactedText = redact(text, secrets: secrets)
            return verifier.verifyRecordedJSON(.string(redactedText)) == .clean ? .string(redactedText) : .string(redacted)
        case .unpairedSurrogateString, .tooDeepContainer:
            return .string(redacted)
        case .array(let values):
            return .array(values.map { redactForRecording($0, secrets: secrets, verifier: verifier, depth: depth + 1) })
        case .object(let members):
            return .object(members.map { member in
                var name = redact(member.key, secrets: secrets)
                if member.keyHasUnpairedSurrogate || verifier.verifyRecordedJSON(.string(name)) != .clean {
                    name = redacted
                }
                if SecretVerifier.isCredentialName(member.key) {
                    return JSONMember(name, member.value == .null ? .null : .string(redacted))
                }
                return JSONMember(name, redactForRecording(member.value, secrets: secrets, verifier: verifier, depth: depth + 1))
            })
        case .null, .bool, .number, .unrepresentableNumber:
            return value
        }
    }

    // MARK: Redaction (best effort)

    /// `text` with every registered secret, masked key form, key-shaped run
    /// and credential value replaced. Best effort: see the type's notes.
    public static func redact(_ text: String, secrets: [String] = []) -> String {
        // A run of combining marks past the verifier's bound is never kept,
        // and string operations on it would cost more than linear time.
        guard SecretNormalization.withinCombiningBound(text) else { return redacted }
        var scalars = Array(text.unicodeScalars)
        var ranges: [Range<Int>] = []
        // Deduplicated by bytes: hashing a String normalises it.
        var seen: Set<[UInt8]> = []
        for secret in secrets where !secret.isEmpty && seen.insert(Array(secret.utf8)).inserted {
            ranges += LinearMatch.ranges(of: Array(secret.unicodeScalars), in: scalars)
        }
        var changed = replace(ranges, in: &scalars)
        if redactMaskedKeys(&scalars) { changed = true }
        var result = changed ? String(String.UnicodeScalarView(scalars)) : text
        if containsKeyShapeTrigger(result) {
            result = result.replacing(keyShapePattern) { _ in redacted }
        }
        if mayHoldCredential(result) {
            result = redactCredentialValues(result, after: namedCredential) { !$0.isWhitespace && !",;\"'&".contains($0) }
            result = redactCredentialValues(result, after: schemeCredential) { character in
                character.isASCII && (character.isLetter || character.isNumber || "._~+/=-".contains(character))
            }
        }
        if result.contains("="), result.contains("?") || result.contains("&") {
            result = redactQueryCredentials(result)
        }
        return result
    }

    /// Whether a key-shaped run (`sk-…`, `AIza…`, `AQ.…`, `pplx-…`) is in `text`.
    static func containsKeyShape(_ text: String) -> Bool {
        containsKeyShapeTrigger(text) && text.contains(keyShapePattern)
    }

    nonisolated(unsafe) static let keyShapePattern = /(?:sk-|AIza)[A-Za-z0-9_\-]{16,}|pplx-[A-Za-z0-9]{24,}|AQ\.[A-Za-z0-9_.\-]{16,}/
    /// A credential name and its separator; the value after it is read by
    /// ``redactCredentialValues(_:after:unquoted:)``.
    nonisolated(unsafe) static let namedCredential =
        /(?i)(?:x-goog-api-key|x-api-key|api[_-]?key|apikey|authorization|access[_-]?token|auth[_-]?token|token|secret|password)["']?\s*[:=]\s*(?:(?:basic|bearer)\s+)?/
    /// `Bearer` or `Basic` before a value, any length, quoted or not.
    nonisolated(unsafe) static let schemeCredential = /(?i)\b(?:bearer|basic)\s+/

    /// Every value after a match of `prefix` replaced, in one forward pass.
    /// A quoted value runs to its closing quote, a backslash escaping the
    /// next character (so `\"` stays inside it), and keeps its quotes; an
    /// unclosed one is replaced to the end of its line. An unquoted value is
    /// the run of characters `unquoted` accepts.
    static func redactCredentialValues(_ text: String, after prefix: Regex<Substring>, unquoted: (Character) -> Bool) -> String {
        var output = ""
        var copied = text.startIndex
        var searchFrom = text.startIndex
        var changed = false
        while searchFrom < text.endIndex, let match = text[searchFrom...].firstMatch(of: prefix) {
            let start = match.range.upperBound
            guard match.range.upperBound > match.range.lowerBound, start < text.endIndex else {
                searchFrom = match.range.upperBound < text.endIndex ? text.index(after: match.range.upperBound) : text.endIndex
                continue
            }
            let opening = text[start]
            var end = start
            var replacement = redacted
            if opening == "\"" || opening == "'" {
                var cursor = text.index(after: start)
                var closed = false
                while cursor < text.endIndex {
                    let character = text[cursor]
                    if character == "\\" {
                        cursor = text.index(after: cursor)
                        if cursor < text.endIndex { cursor = text.index(after: cursor) }
                        continue
                    }
                    if character == opening {
                        closed = true
                        break
                    }
                    if character.isNewline { break }
                    cursor = text.index(after: cursor)
                }
                end = closed ? text.index(after: cursor) : cursor
                replacement = closed ? "\(opening)\(redacted)\(opening)" : "\(opening)\(redacted)"
            } else {
                while end < text.endIndex, unquoted(text[end]) { end = text.index(after: end) }
            }
            if end > start {
                output += text[copied..<start]
                output += replacement
                copied = end
                changed = true
            }
            searchFrom = end > start ? end : start
        }
        guard changed else { return text }
        output += text[copied...]
        return output
    }

    /// Query parameters read in one forward pass: after each `?` or `&`, a
    /// name up to `=` (stopping at any delimiter), then its value; a value
    /// whose percent-decoded name is a credential name is replaced.
    static func redactQueryCredentials(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        func ends(_ scalar: Unicode.Scalar) -> Bool {
            scalar == "&" || scalar == "#" || scalar == "\"" || scalar == "'" || scalar == "<" || scalar == ">"
                || scalar.properties.isWhitespace
        }
        var output = String.UnicodeScalarView()
        var index = 0
        var changed = false
        while index < scalars.count {
            let scalar = scalars[index]
            output.append(scalar)
            index += 1
            guard scalar == "?" || scalar == "&" else { continue }
            var nameEnd = index
            while nameEnd < scalars.count, scalars[nameEnd] != "=", scalars[nameEnd] != "?", !ends(scalars[nameEnd]) { nameEnd += 1 }
            guard nameEnd > index, nameEnd < scalars.count, scalars[nameEnd] == "=" else {
                output.append(contentsOf: scalars[index..<nameEnd])
                index = nameEnd
                continue
            }
            var valueEnd = nameEnd + 1
            while valueEnd < scalars.count, !ends(scalars[valueEnd]) { valueEnd += 1 }
            output.append(contentsOf: scalars[index...nameEnd])
            if isCredentialQueryName(String(String.UnicodeScalarView(scalars[index..<nameEnd]))) {
                output.append(contentsOf: redacted.unicodeScalars)
                changed = true
            } else {
                output.append(contentsOf: scalars[(nameEnd + 1)..<valueEnd])
            }
            index = valueEnd
        }
        return changed ? String(output) : text
    }

    static let credentialQueryNames: Set<String> = SecretVerifier.credentialNames.union(["auth", "access-token", "api_token"])

    static func isCredentialQueryName(_ name: String) -> Bool {
        let decoded: String
        switch SecretDecodings.percentDecoded(name) {
        case .decoded(let texts): decoded = texts.first ?? name
        default: decoded = name
        }
        guard let normalised = SecretNormalization.stripped(decoded) else { return true }
        return credentialQueryNames.contains(String(String.UnicodeScalarView(normalised)))
    }

    static func containsKeyShapeTrigger(_ text: String) -> Bool {
        ["sk-", "AIza", "pplx-", "AQ."].contains { text.contains($0) }
    }

    /// Whether `text` may hold a credential name or scheme, read the way the
    /// patterns read it (case-insensitively, Unicode case folding): plain
    /// ASCII text takes a cheap path, any other text is folded in full.
    static func mayHoldCredential(_ text: String) -> Bool {
        let names = ["key", "token", "authorization", "secret", "password", "bearer", "basic"]
        let folded = text.utf8.allSatisfy({ $0 < 0x80 })
            ? ProviderJSON.lowercasedASCII(text)
            : text.folding(options: [.caseInsensitive], locale: nil)
        return names.contains { folded.contains($0) }
    }

    /// Replaces each run of overlapping `ranges` with one `[REDACTED]`.
    static func replace(_ ranges: [Range<Int>], in scalars: inout [Unicode.Scalar]) -> Bool {
        guard !ranges.isEmpty else { return false }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(scalars.count)
        var copied = 0
        var current = sorted[0]
        func emit(_ range: Range<Int>) {
            output.append(contentsOf: scalars[copied..<range.lowerBound])
            output.append(contentsOf: redacted.unicodeScalars)
            copied = range.upperBound
        }
        for range in sorted.dropFirst() {
            if range.lowerBound < current.upperBound {
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                emit(current)
                current = range
            }
        }
        emit(current)
        output.append(contentsOf: scalars[copied...])
        scalars = output
        return true
    }

    /// Masked key forms, in one pass: a masking run (masking characters and
    /// dots, with at least one masking character or three dots) is
    /// redacted with the token characters touching it when it holds four or
    /// more masking characters or the token before it starts with a key
    /// prefix, as in `sk-proj-***abcd`. Token ends are known before the scan
    /// and the output's trailing token is tracked as it grows.
    static func redactMaskedKeys(_ scalars: inout [Unicode.Scalar]) -> Bool {
        guard scalars.contains(where: { isMask($0) || $0 == "." }) else { return false }
        let count = scalars.count
        // chainEnd[i]: the end of the masked token from i on, every token,
        // masking and glue scalar in a row, so a redaction takes the whole
        // of `sk-proj-***middle***abcd` and not just its first run.
        var chainEnd = [Int](repeating: count, count: count + 1)
        for position in stride(from: count - 1, through: 0, by: -1) {
            let chained = isToken(scalars[position]) || isMask(scalars[position]) || scalars[position] == "."
            chainEnd[position] = chained ? max(chainEnd[position + 1], position + 1) : position
        }
        var output: [Unicode.Scalar] = []
        output.reserveCapacity(count)
        var tokenStart = 0
        var replaced = false
        func append(_ scalar: Unicode.Scalar) {
            if !isToken(scalar) {
                tokenStart = output.count + 1
            } else if output.last.map(isToken) != true {
                tokenStart = output.count
            }
            output.append(scalar)
        }
        var index = 0
        while index < count {
            guard isMask(scalars[index]) || scalars[index] == "." else {
                append(scalars[index])
                index += 1
                continue
            }
            var end = index
            var masks = 0
            var dots = 0
            while end < count, isMask(scalars[end]) || scalars[end] == "." {
                if scalars[end] == "." { dots += 1 } else { masks += 1 }
                end += 1
            }
            guard masks > 0 || dots >= 3 else {
                for scalar in scalars[index..<end] { append(scalar) }
                index = end
                continue
            }
            let leftCount = output.count - tokenStart
            let keyed = keyPrefixScalars.contains { output[tokenStart...].starts(with: $0) }
            if masks >= 4 || keyed {
                output.removeLast(leftCount)
                for scalar in redacted.unicodeScalars { append(scalar) }
                index = chainEnd[end]
                replaced = true
            } else {
                for scalar in scalars[index..<end] { append(scalar) }
                index = end
            }
        }
        guard replaced else { return false }
        scalars = output
        return true
    }

    static let keyPrefixScalars = ["sk-", "AIza", "AQ.", "pplx-"].map { Array($0.unicodeScalars) }

    static func isMask(_ scalar: Unicode.Scalar) -> Bool {
        SecretNormalization.maskScalars.contains(scalar) || scalar == "\u{FF0A}"
    }

    /// Token characters, and the glue a credential may hide behind
    /// (format, default-ignorable and combining characters, spacing marks
    /// included).
    static func isToken(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", ".", "-":
            return true
        default:
            let category = scalar.properties.generalCategory
            return category == .format || category == .nonspacingMark || category == .enclosingMark || category == .spacingMark
                || scalar.properties.isDefaultIgnorableCodePoint
        }
    }
}

extension RedactingLogger: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "RedactingLogger(secrets: \(secrets.count))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["secretCount": secrets.count]) }
}
