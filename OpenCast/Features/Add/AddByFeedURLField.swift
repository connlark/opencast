import SwiftUI

struct AddByFeedURLField: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let offersPaste: Bool
    let onSubmit: () -> Void
    let onPaste: (String) -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Feed URL", text: $text, prompt: Text("https://example.com/feed.xml"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused(isFocused)
                .onSubmit(onSubmit)
                .accessibilityLabel("Feed URL")
                .accessibilityIdentifier("RSS Feed URL")

            if !text.isEmpty {
                Button(action: clear) {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .foregroundStyle(.tertiary)
                .buttonStyle(.plain)
            } else if offersPaste {
                PasteButton(payloadType: String.self, onPaste: paste)
                    .labelStyle(.titleOnly)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(minHeight: 50)
        .background(.fill.tertiary, in: .capsule)
    }

    private func clear() {
        text = ""
        isFocused.wrappedValue = true
    }

    private func paste(_ strings: [String]) {
        if let string = strings.first {
            onPaste(string)
        }
    }
}
