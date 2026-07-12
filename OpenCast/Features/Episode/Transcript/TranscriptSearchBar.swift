import SwiftUI

struct TranscriptSearchBar: View {
    @Binding var query: String
    let isSearching: Bool
    let matchCount: Int
    let currentMatchOrdinal: Int?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .padding(.leading, 12)

            TextField("Search Transcript", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .focused($isFieldFocused)
                .onSubmit(dismissKeyboard)

            if isSearching {
                ProgressView()
                    .controlSize(.small)
                    .padding(.horizontal, 4)
            } else if !query.isEmpty {
                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .layoutPriority(1)
            }

            Button("Previous Match", systemImage: "chevron.up", action: onPrevious)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
                .disabled(matchCount == 0)

            Button("Next Match", systemImage: "chevron.down", action: onNext)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
                .disabled(matchCount == 0)

            Button("Close Search", systemImage: "xmark.circle.fill", action: onClose)
                .frame(width: 36, height: 44)
                .contentShape(.rect)
                .foregroundStyle(.secondary)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 6)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: .capsule)
        .onAppear(perform: focusField)
    }

    private var statusText: String {
        guard matchCount > 0 else {
            return "No Matches"
        }
        return "\(currentMatchOrdinal ?? 0) of \(matchCount)"
    }

    private func focusField() {
        isFieldFocused = true
    }

    private func dismissKeyboard() {
        isFieldFocused = false
    }
}
