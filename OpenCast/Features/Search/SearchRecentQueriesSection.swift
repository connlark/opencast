import SwiftUI

struct SearchRecentQueriesSection: View {
    let queries: [String]
    let onSelect: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        Section {
            ForEach(queries, id: \.self) { query in
                Button {
                    onSelect(query)
                } label: {
                    Label(query, systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        } header: {
            HStack {
                Text("Recently Searched")
                Spacer()
                Button("Clear", action: onClear)
                    .textCase(nil)
            }
        }
    }
}
