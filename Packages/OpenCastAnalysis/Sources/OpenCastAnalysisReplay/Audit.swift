import Foundation
import OpenCastAnalysis
import OpenCastAnalysisProviders

/// `audit`: how the recorder sink would treat existing artifacts with the
/// given keys registered, as counts only. Measures how often the 4-scalar
/// fragment check flags provider text that holds no key (its false
/// positives). Never prints a key, a fragment or any artifact text.
struct Audit {
    let arguments: Arguments

    func run() throws -> JSONValue {
        let secrets = try (arguments.options["key-files"] ?? "").split(separator: ",").map { path in
            let text = try String(contentsOfFile: String(path), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw AnalysisReplay.InputError(description: "empty key file") }
            return text
        }
        guard !secrets.isEmpty else { throw AnalysisReplay.InputError(description: "audit needs --key-files PATH[,PATH]") }
        let root = URL(filePath: try arguments.required("root"), directoryHint: .isDirectory)
        let verifier = SecretVerifier(secrets: secrets)
        var counts: [String: Int] = [:]
        func add(_ name: String, _ value: Int = 1) { counts[name, default: 0] += value }
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            switch file.pathExtension {
            case "json":
                add("json_files")
                guard let value = try? JSONParser.parse(text) else {
                    add("json_files_not_json")
                    continue
                }
                var strings = 0, flagged = 0, names = 0, flaggedNames = 0
                func walk(_ value: JSONValue) {
                    switch value {
                    case .string(let string):
                        strings += 1
                        switch verifier.verifyRecordedJSON(.string(RedactingLogger.redact(string, secrets: secrets))) {
                        case .clean: break
                        case .secretFragment:
                            flagged += 1
                            add("strings_flagged_fragment")
                        case .exhausted:
                            flagged += 1
                            add("strings_flagged_bound")
                        }
                    case .array(let values):
                        values.forEach(walk)
                    case .object(let members):
                        for member in members {
                            names += 1
                            if verifier.verifyRecordedJSON(.string(member.key)) != .clean { flaggedNames += 1 }
                            walk(member.value)
                        }
                    case .tooDeepContainer:
                        // Nested past the parser's limit: syntax-checked but not kept,
                        // so its text cannot be inspected.
                        flagged += 1
                        add("strings_flagged_bound")
                    case .null, .bool, .number, .unpairedSurrogateString, .unrepresentableNumber:
                        break
                    }
                }
                walk(value)
                add("strings", strings)
                add("strings_flagged", flagged)
                add("names", names)
                add("names_flagged", flaggedNames)
                if flagged + flaggedNames > 0 { add("json_files_with_a_flagged_value") }
                if !RedactingLogger.safeRecording(value, secrets: secrets).recorded { add("json_files_suppressed") }
            case "log":
                for line in text.split(separator: "\n") {
                    add("log_lines")
                    if RedactingLogger.safeLine(String(line), secrets: secrets) == RedactingLogger.redactedLine { add("log_lines_redacted") }
                }
            default:
                continue
            }
        }
        add("keys", secrets.count)
        return .object(counts.sorted { $0.key < $1.key }.map { JSONMember($0.key, .integer($0.value)) })
    }
}
