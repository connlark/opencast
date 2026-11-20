import Foundation

/// Built from run records only, never an analysis record, document or transcript, and every
/// string is an enum value or passes a closed grammar: no title, text, key or address may
/// reach it.
nonisolated enum AnalysisRunsExport {
    static let formatVersion = 1
    static let maximumRuns = 200
    static let fileName = "OpenCast-AnalysisRuns.json"

    static func data(entries: [AnalysisRunsExportEntry], generatedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            Envelope(
                formatVersion: formatVersion,
                generatedAt: generatedAt,
                analysisRuns: Array(entries.prefix(maximumRuns))
            )
        )
    }

    static func write(entries: [AnalysisRunsExportEntry], generatedAt: Date, to destination: URL) throws -> URL {
        guard !entries.isEmpty else {
            throw AnalysisRunsExportError.empty
        }
        do {
            let data = try data(entries: entries, generatedAt: generatedAt)
            try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return destination
        } catch {
            throw AnalysisRunsExportError.unavailable
        }
    }

    private struct Envelope: Encodable {
        let formatVersion: Int
        let generatedAt: Date
        let analysisRuns: [AnalysisRunsExportEntry]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case generatedAt = "generated_at"
            case analysisRuns = "analysis_runs"
        }
    }
}

nonisolated enum AnalysisRunsExportError: Error, LocalizedError, Equatable {
    case empty
    case unavailable

    var errorDescription: String? {
        switch self {
        case .empty:
            "No analysis runs yet."
        case .unavailable:
            "The analysis runs export couldn’t be prepared. Try again."
        }
    }
}
