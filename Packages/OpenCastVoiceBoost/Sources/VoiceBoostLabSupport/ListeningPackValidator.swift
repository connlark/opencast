import Foundation

struct ListeningPackValidationResult: Codable {
    var packPath: String
    var passed: Bool
    var checkedFiles: [String]
    var missingFiles: [String]
    var errors: [String]
    var warnings: [String]
    var readiness: ListeningPackReadiness?
}

enum ListeningPackValidator {
    static func validate(packDirectory: URL) throws -> ListeningPackValidationResult {
        let summaryURL = packDirectory.appending(path: "summary.json")
        guard FileManager.default.fileExists(atPath: summaryURL.path) else {
            return ListeningPackValidationResult(
                packPath: packDirectory.path,
                passed: false,
                checkedFiles: ["summary.json"],
                missingFiles: ["summary.json"],
                errors: ["Missing summary.json."],
                warnings: [],
                readiness: nil
            )
        }

        let summary = try JSONDecoder().decode(
            ListeningPackSummary.self,
            from: Data(contentsOf: summaryURL)
        )
        let missingFiles = summary.files.filter {
            !FileManager.default.fileExists(atPath: packDirectory.appending(path: $0).path)
        }
        var errors = missingFiles.map { "Missing artifact: \($0)." }

        errors.append(contentsOf: readinessErrors(summary.readiness))
        errors.append(contentsOf: audioErrors(summary.dry, label: "dry"))
        errors.append(contentsOf: audioErrors(summary.boosted, label: "boosted"))
        errors.append(contentsOf: audioErrors(summary.toggle, label: "toggle"))
        if let reference = summary.reference {
            errors.append(contentsOf: audioErrors(reference, label: "reference"))
        }
        if let alignedDry = summary.alignedDry {
            errors.append(contentsOf: audioErrors(alignedDry, label: "alignedDry"))
        }
        if let alignedBoosted = summary.alignedBoosted {
            errors.append(contentsOf: audioErrors(alignedBoosted, label: "alignedBoosted"))
        }
        if let alignedReference = summary.alignedReference {
            errors.append(contentsOf: audioErrors(alignedReference, label: "alignedReference"))
        }

        return ListeningPackValidationResult(
            packPath: packDirectory.path,
            passed: errors.isEmpty,
            checkedFiles: summary.files,
            missingFiles: missingFiles,
            errors: errors,
            warnings: summary.reviewWarnings,
            readiness: summary.readiness
        )
    }

    private static func readinessErrors(_ readiness: ListeningPackReadiness) -> [String] {
        var errors: [String] = []
        if !readiness.metricOnly {
            errors.append("Listening pack summary must remain metric-only.")
        }
        if !readiness.humanListeningRequired {
            errors.append("Listening pack summary must require human listening.")
        }
        if !readiness.deviceRuntimeRequired {
            errors.append("Listening pack summary must require device runtime verification.")
        }
        if readiness.releaseApproved {
            errors.append("Listening pack summary must not approve release.")
        }
        return errors
    }

    private static func audioErrors(_ metrics: AudioMetricsSummary, label: String) -> [String] {
        var errors: [String] = []
        if metrics.clippedSampleCount > 0 {
            errors.append("\(label) has \(metrics.clippedSampleCount) clipped samples.")
        }
        if metrics.nanInfSampleCount > 0 {
            errors.append("\(label) has \(metrics.nanInfSampleCount) NaN/Inf samples.")
        }
        return errors
    }
}
