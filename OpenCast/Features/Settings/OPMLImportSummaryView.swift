import SwiftUI

struct OPMLImportSummaryView: View {
    let result: OPMLImportResult

    var body: some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 2) {
                if result.importedCount > 0 {
                    Text("^[\(result.importedCount) feed](inflect: true) imported")
                }

                if result.skippedDuplicateCount > 0 {
                    Text("^[\(result.skippedDuplicateCount) feed](inflect: true) skipped")
                }

                if result.failedCount > 0 {
                    Text("^[\(result.failedCount) feed](inflect: true) failed")
                }

                if result.importedCount == 0,
                   result.skippedDuplicateCount == 0,
                   result.failedCount == 0 {
                    Text("No feeds changed")
                }
            }
        } label: {
            Label("Import Result", systemImage: "list.bullet.clipboard")
        }

        if !result.failures.isEmpty {
            ForEach(result.failures) { failure in
                LabeledContent {
                    Text(failure.message)
                        .foregroundStyle(.secondary)
                } label: {
                    Label(failure.title ?? failure.feedURL, systemImage: "exclamationmark.triangle")
                }
            }
        }
    }
}
