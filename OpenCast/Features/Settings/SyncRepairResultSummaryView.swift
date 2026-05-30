import SwiftUI

struct SyncRepairResultSummaryView: View {
    let result: SyncRepairResult

    var body: some View {
        Group {
            LabeledContent {
                Text(result.displayStatus)
            } label: {
                Label("Last Repair", systemImage: "clock.badge.checkmark")
            }
            .accessibilityLabel("Last Repair, \(result.displayStatus)")
            LabeledContent {
                Text("\(result.duplicateRecordsFound)")
            } label: {
                Label("Duplicate Rows", systemImage: "rectangle.on.rectangle")
            }
            LabeledContent {
                Text("\(result.groupsMerged)")
            } label: {
                Label("Merged Groups", systemImage: "arrow.triangle.merge")
            }
            LabeledContent {
                Text("\(result.recordsDeleted)")
            } label: {
                Label("Deleted Rows", systemImage: "trash")
            }
        }
    }
}
