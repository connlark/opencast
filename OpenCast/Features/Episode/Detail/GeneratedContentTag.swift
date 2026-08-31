import SwiftUI

/// Shared "Generated" marker for AI-produced content cards; every generated
/// surface must carry it (the generate disclosure promises labeled output).
struct GeneratedContentTag: View {
    var body: some View {
        Label("Generated", systemImage: "sparkles")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
