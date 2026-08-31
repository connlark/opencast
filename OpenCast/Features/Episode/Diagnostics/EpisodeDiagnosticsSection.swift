import Foundation

/// One rendered block of the diagnostics report: ordered label/value rows
/// plus an optional footnote. The same rows feed the sheet UI and the
/// plain-text report so both always agree.
nonisolated struct EpisodeDiagnosticsSection: Sendable, Equatable {
    nonisolated struct Row: Sendable, Equatable, Identifiable {
        let id: Int
        let label: String
        let value: String
    }

    let rows: [Row]
    let footnote: String?

    init(rows: [(label: String, value: String)], footnote: String? = nil) {
        self.rows = rows.enumerated().map { index, row in
            Row(id: index, label: row.label, value: row.value)
        }
        self.footnote = footnote
    }
}
