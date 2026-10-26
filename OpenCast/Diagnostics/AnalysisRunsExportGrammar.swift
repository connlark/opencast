import Foundation

/// The closed grammars the analysis-runs export checks its free-form
/// fields against. A value that fails becomes `invalid`, so a signed policy
/// or a damaged run record can never carry prose, an address or a key into
/// the export.
nonisolated enum AnalysisRunsExportGrammar {
    static let invalid = "invalid"

    static func runID(_ value: String) -> String {
        UUID(uuidString: value) == nil ? invalid : value
    }

    static func modelID(_ value: String) -> String {
        identifier(value, maximumLength: 128)
    }

    static func policyRevision(_ value: String) -> String {
        identifier(value, maximumLength: 64)
    }

    /// `[A-Za-z0-9._-]{1,maximumLength}`.
    static func identifier(_ value: String, maximumLength: Int) -> String {
        guard (1...maximumLength).contains(value.unicodeScalars.count),
              value.unicodeScalars.allSatisfy(isIdentifierScalar)
        else {
            return invalid
        }
        return value
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar)
            || ("A"..."Z").contains(scalar)
            || ("0"..."9").contains(scalar)
            || scalar == "." || scalar == "_" || scalar == "-"
    }
}
