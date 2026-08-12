import Foundation

/// Helpers shared by the opt-in benchmark and evaluation harness runners
/// (transcription and search): launch-argument parsing, report-file naming,
/// environment identifiers, and JSON report writing.
nonisolated enum BenchmarkHarnessSupport {
    static func argumentValue(
        from arguments: [String],
        flag: String
    ) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument.hasPrefix("\(flag)=") {
                return String(argument.dropFirst(flag.count + 1))
            }
            if argument == flag, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }
        }
        return nil
    }

    static func safeStem(_ rawValue: String) -> String {
        let allowedScalars = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        var value = ""
        for scalar in rawValue.unicodeScalars {
            if allowedScalars.contains(scalar) {
                value.unicodeScalars.append(scalar)
            } else {
                value.append("-")
            }
        }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        return String((trimmed.isEmpty ? "run" : trimmed).prefix(96))
    }

    static var buildMode: String {
        #if DEBUG
        "Debug"
        #else
        "Release"
        #endif
    }

    static var thermalStateDescription: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func machineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafeBytes(of: &systemInfo.machine) { buffer in
            let bytes = buffer.prefix(while: { $0 != 0 })
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func prepareReportDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try LocalBackupExclusion.apply(to: url)
    }

    static func writeJSONReport(_ value: some Encodable, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}
